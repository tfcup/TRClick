import Foundation
import Testing
@testable import TRClick

@MainActor
struct UpdaterTests {
    private func makeChecker(response: String = "release") -> (GitHubReleaseChecker, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateManifestURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Response": response]
        let session = URLSession(configuration: configuration)
        return (GitHubReleaseChecker(owner: "tfcup", repo: "TRClick", session: session), session)
    }

    @Test func newerManifestOffersThePublishedApplication() async throws {
        let (checker, session) = makeChecker()
        defer { session.invalidateAndCancel() }

        let result = await checker.checkForUpdate(currentVersion: "0.1.4")
        guard case .updateAvailable(let release) = result else {
            Issue.record("Expected an available update from the release manifest")
            return
        }
        #expect(release.version == "0.1.5")
        #expect(release.body == "Release notes")
        #expect(release.assets.first?.browserDownloadUrl == "https://github.com/tfcup/TRClick/releases/download/v0.1.5/TRClick-v0.1.5.app.zip")
    }

    @Test(arguments: ["0.1.5", "0.1.6"])
    func currentOrNewerVersionIsUpToDate(version: String) async {
        let (checker, session) = makeChecker()
        defer { session.invalidateAndCancel() }

        guard case .upToDate = await checker.checkForUpdate(currentVersion: version) else {
            Issue.record("The manifest must not offer the same or an older version")
            return
        }
    }

    @Test(arguments: [403, 404, 503])
    func httpErrorsKeepTheirMeaning(status: Int) async {
        let (checker, session) = makeChecker(response: "http-\(status)")
        defer { session.invalidateAndCancel() }

        guard case .failed(let reason) = await checker.checkForUpdate(currentVersion: "0.1.4") else {
            Issue.record("An HTTP failure must not be reported as up to date")
            return
        }
        #expect(reason == UpdateCheckError.httpStatus(status).localizedDescription)
        #expect(!reason.contains("-1011"))
    }

    @Test func invalidManifestIsReportedAsAParsingFailure() async {
        let (checker, session) = makeChecker(response: "invalid-json")
        defer { session.invalidateAndCancel() }

        guard case .failed(let reason) = await checker.checkForUpdate(currentVersion: "0.1.4") else {
            Issue.record("Invalid update information must fail the check")
            return
        }
        #expect(reason == UpdateCheckError.invalidManifest.localizedDescription)
    }

    @Test(arguments: ["offline", "timeout"])
    func networkFailuresHaveActionableMessages(response: String) async {
        let (checker, session) = makeChecker(response: response)
        defer { session.invalidateAndCancel() }

        guard case .failed(let reason) = await checker.checkForUpdate(currentVersion: "0.1.4") else {
            Issue.record("A network error must fail the update check")
            return
        }
        let key = response == "offline"
            ? "You appear to be offline. Check your connection and try again."
            : "The update check timed out. Please try again later."
        #expect(reason == AppLocalization.localized(key))
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TRClick"
    }

    private func makeApp(in directory: URL, version: String, identifier: String? = nil) throws -> URL {
        let app = directory.appendingPathComponent("\(appName).app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/\(appName)")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier ?? Bundle.main.bundleIdentifier ?? "com.tfcup.TRClick",
            "CFBundleName": appName, "CFBundleExecutable": appName,
            "CFBundlePackageType": "APPL", "CFBundleVersion": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n# \(version)\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(version.utf8).write(to: contents.appendingPathComponent("version.txt"))
        return app
    }

    @Test func invalidUpdateThrowsAndKeepsTheInstalledApplication() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("TRClick-update-test-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let destination = root.appendingPathComponent("applications")
        let oldApp = try makeApp(in: destination, version: "old")
        let invalidApp = try makeApp(in: root.appendingPathComponent("download"), version: "new", identifier: "invalid.bundle")
        let updater = UpdateManager(owner: "unused", repo: "unused", currentVersion: "0")

        await #expect(throws: (any Error).self) {
            try await updater.installApplication(appURL: invalidApp, applicationsDirectory: destination)
        }
        await #expect(throws: (any Error).self) {
            try await updater.installApplication(appURL: root.appendingPathComponent("missing.app"), applicationsDirectory: destination)
        }

        #expect(try String(contentsOf: oldApp.appendingPathComponent("Contents/version.txt"), encoding: .utf8) == "old")
        #expect(try manager.contentsOfDirectory(atPath: destination.path) == [oldApp.lastPathComponent])
    }

    @Test func validUpdateReplacesTheApplicationAfterStaging() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("TRClick-update-test-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let destination = root.appendingPathComponent("applications")
        let oldApp = try makeApp(in: destination, version: "old")
        let update = try makeApp(in: root.appendingPathComponent("download"), version: "new")
        let updater = UpdateManager(owner: "unused", repo: "unused", currentVersion: "0")

        try await updater.installApplication(appURL: update, applicationsDirectory: destination)

        #expect(try String(contentsOf: oldApp.appendingPathComponent("Contents/version.txt"), encoding: .utf8) == "new")
        #expect(try manager.contentsOfDirectory(atPath: destination.path) == [oldApp.lastPathComponent])
    }

    @Test func archiveWithManyEntriesExtractsWithoutBlockingOnOutput() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("TRClick-extraction-test-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let app = try makeApp(in: root, version: "new")
        let resources = app.appendingPathComponent("Contents/Resources")
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        for index in 0..<512 {
            try Data().write(to: resources.appendingPathComponent("\(index)-\(String(repeating: "x", count: 96)).txt"))
        }
        let archive = root.appendingPathComponent("update.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", app.path, archive.path]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        let updater = UpdateManager(owner: "unused", repo: "unused", currentVersion: "0")

        let extracted = try await updater.extractAppZip(zipURL: archive)
        defer { try? manager.removeItem(at: extracted.deletingLastPathComponent()) }

        #expect(try manager.contentsOfDirectory(atPath: extracted.appendingPathComponent("Contents/Resources").path).count == 512)
        await #expect(throws: (any Error).self) {
            try await updater.extractAppZip(zipURL: root.appendingPathComponent("missing.zip"))
        }
    }
}

/// 按请求头选择固定响应，测试不依赖真实网络，也不共享可变的响应处理器。
nonisolated private final class UpdateManifestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // 同时验证客户端始终请求动态清单，并绕过本地旧缓存。
        guard request.url?.absoluteString == "https://github.com/tfcup/TRClick/releases/latest/download/update.json",
              request.cachePolicy == .reloadIgnoringLocalCacheData,
              request.value(forHTTPHeaderField: "Cache-Control") == "no-cache" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let scenario = request.value(forHTTPHeaderField: "X-Test-Response") ?? "release"
        if scenario == "offline" || scenario == "timeout" {
            let code: URLError.Code = scenario == "offline" ? .notConnectedToInternet : .timedOut
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let status = scenario.hasPrefix("http-") ? Int(scenario.dropFirst(5))! : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let manifest = """
        {
          "id": 1, "tag_name": "v0.1.5", "name": "TRClick v0.1.5",
          "body": "Release notes", "draft": false, "prerelease": false,
          "published_at": "2026-11-12T08:00:00Z",
          "html_url": "https://github.com/tfcup/TRClick/releases/tag/v0.1.5",
          "assets": [{
            "id": 2, "name": "TRClick-v0.1.5.app.zip", "size": 1024,
            "browser_download_url": "https://github.com/tfcup/TRClick/releases/download/v0.1.5/TRClick-v0.1.5.app.zip",
            "content_type": "application/zip"
          }]
        }
        """
        let data = Data((scenario == "invalid-json" ? "invalid-json" : manifest).utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
