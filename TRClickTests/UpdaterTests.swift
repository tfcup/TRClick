import Foundation
import Testing
@testable import TRClick

@MainActor
struct UpdaterTests {
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
