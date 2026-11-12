//
//  Updater.swift
//  TRClick
//
//  Created by 李旭 on 2025/9/21.
//

import Combine
import Foundation
import SwiftUI

// MARK: - 数据模型

struct GitHubRelease: Codable, Identifiable {
    let id: Int
    let tagName: String
    let name: String
    let body: String
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date
    let assets: [Asset]
    let htmlUrl: String
    
    var version: String {
        tagName.replacingOccurrences(of: "v", with: "")
    }
    
    struct Asset: Codable {
        let id: Int
        let name: String
        let browserDownloadUrl: String
        let size: Int
        let contentType: String?
        
        enum CodingKeys: String, CodingKey {
            case id, name, size
            case browserDownloadUrl = "browser_download_url"
            case contentType = "content_type"
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name, body, draft, prerelease, assets
        case publishedAt = "published_at"
        case htmlUrl = "html_url"
    }
}

// MARK: - 用户偏好设置

class UpdatePreferences: ObservableObject {
    let objectWillChange: ObservableObjectPublisher = ObservableObjectPublisher()

    init() {}

    @AppStorage("ignoredVersion") private var ignoredVersionData: Data = .init()
    
    // 获取忽略的版本列表
    var ignoredVersions: [String] {
        get {
            do {
                return try JSONDecoder().decode([String].self, from: ignoredVersionData)
            } catch {
                return []
            }
        }
        set {
            do {
                ignoredVersionData = try JSONEncoder().encode(newValue)
            } catch {
                print("Failed to save ignored versions: \(error)")
            }
        }
    }
    
    // 忽略特定版本
    func ignoreVersion(_ version: String) {
        var ignored = ignoredVersions
        if !ignored.contains(version) {
            ignored.append(version)
            ignoredVersions = ignored
        }
    }
    
    // 检查版本是否被忽略
    func isVersionIgnored(_ version: String) -> Bool {
        ignoredVersions.contains(version)
    }
}

// MARK: - GitHub 发布服务

/// 一次更新检查的结果。
///
/// 以前 `checkForUpdate` 返回 `GitHubRelease?`，那一个 `nil` 同时背着三种含义：
/// 网络失败、最新 release 是草稿/预发布、确实已是最新。而 `catch` 又把真实的网络
/// 错误吞成一句 `print`，上层拿到 `nil` 只能一律当成「已是最新」——所以断网会被
/// 报成「已是最新」。三种情况不拆开，界面就没法说实话。
enum UpdateCheckResult {
    case updateAvailable(GitHubRelease)
    case upToDate
    case failed(String)
}

nonisolated enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidManifest

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return AppLocalization.localized("The update server did not return a valid HTTP response.")
        case .httpStatus(404):
            return AppLocalization.localized("Update information is not available yet. Please open the release page to check for updates.")
        case .httpStatus(let status):
            return String(format: AppLocalization.localized("The update server returned HTTP %ld. Please try again later."), status)
        case .invalidManifest:
            return AppLocalization.localized("The update information is invalid. Please open the release page to download manually.")
        }
    }
}

class GitHubReleaseChecker {
    private let owner: String
    private let repo: String
    private let session: URLSession
    
    init(owner: String, repo: String, session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.session = session
    }
    
    /// 从最新正式版附件读取发布清单，避免匿名 REST API 的共享 IP 限流。
    func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/update.json")!
        // latest 会随正式版发布改变；每次检查都重新获取或验证，避免本地缓存滞后。
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.invalidManifest
        }
    }

    /// 拉仓库的星标数。走 `/repos/{owner}/{repo}`，和 release 是两个端点。
    func fetchStarCount() async throws -> Int {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        struct Repository: Decodable {
            let stargazersCount: Int
            enum CodingKeys: String, CodingKey { case stargazersCount = "stargazers_count" }
        }
        return try JSONDecoder().decode(Repository.self, from: data).stargazersCount
    }

    // 检查是否需要更新。
    // 返回枚举而不是 `GitHubRelease?`：那个 `nil` 原来同时背着「网络失败」
    // 「最新 release 是草稿或预发布」「确实已是最新」三种含义，而 `catch` 又把
    // 真实的网络错误吞成一句 `print`，上层只能一律当成「已是最新」——
    // 于是断网会被报成「已是最新」。三种情况分开，界面才可能说实话。
    func checkForUpdate(currentVersion: String, includePrereleases: Bool = false) async -> UpdateCheckResult {
        do {
            let latestRelease = try await fetchLatestRelease()

            // 草稿版和预发布版不算可更新版本，但这是一次成功的检查
            if latestRelease.draft || (!includePrereleases && latestRelease.prerelease) {
                return .upToDate
            }

            if compareVersions(currentVersion, latestRelease.version) == .orderedAscending {
                return .updateAvailable(latestRelease)
            }

            return .upToDate
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet:
                return .failed(AppLocalization.localized("You appear to be offline. Check your connection and try again."))
            case .timedOut:
                return .failed(AppLocalization.localized("The update check timed out. Please try again later."))
            default:
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
    
    // 语义化版本比较
    private func compareVersions(_ version1: String, _ version2: String) -> ComparisonResult {
        let components1 = version1.components(separatedBy: ".")
        let components2 = version2.components(separatedBy: ".")
        
        for i in 0 ..< max(components1.count, components2.count) {
            let part1 = i < components1.count ? components1[i] : "0"
            let part2 = i < components2.count ? components2[i] : "0"
            
            if let num1 = Int(part1), let num2 = Int(part2) {
                if num1 < num2 { return .orderedAscending }
                if num1 > num2 { return .orderedDescending }
            } else {
                // 处理非数字部分（如beta、rc等）
                let comparison = part1.compare(part2)
                if comparison != .orderedSame {
                    return comparison
                }
            }
        }
        
        return .orderedSame
    }
}

// MARK: - 更新管理器

@MainActor
class UpdateManager: ObservableObject {
    @Published var availableUpdate: GitHubRelease?
    @Published var isChecking = false
    @Published var updateError: String?
    /// 上一次检查的结论是「已是最新」。
    ///
    /// 单独一个字段，不再借用 `updateError`：借用会让界面无法区分「检查成功且已是最新」
    /// 和「检查失败」，弹窗里那张绿色「Up to Date」卡片也因此永远走不到。
    @Published var isUpToDate = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var showUpdateSheet = false

    /// 仓库星标数。nil 表示还没拿到——界面就不显示数字，不占位、不报错。
    @Published private(set) var starCount: Int?
    
    private let githubChecker: GitHubReleaseChecker
    private let preferences: UpdatePreferences
    private let currentVersion: String
    /// 存下来只为拼仓库/Issues 地址，别处不再硬编码 URL。
    private let owner: String
    private let repo: String

    /// 是否来自 Mac App Store（通过 `Contents/_MASReceipt/receipt` 是否存在判断）。
    /// App Store 构建禁止自更新（MAS 审核要求），改为引导用户去 App Store 更新。
    private var isAppStoreBuild: Bool {
        let receiptPath = Bundle.main.bundlePath + "/Contents/_MASReceipt/receipt"
        return FileManager.default.fileExists(atPath: receiptPath)
    }

    init(owner: String, repo: String, currentVersion: String) {
        self.githubChecker = GitHubReleaseChecker(owner: owner, repo: repo)
        self.preferences = UpdatePreferences()
        self.currentVersion = currentVersion
        self.owner = owner
        self.repo = repo
    }

    // MARK: - 星标数

    private enum StarCache {
        static let count = "githubStarCount"
        static let fetchedAt = "githubStarCountFetchedAt"
        /// 一天拉一次。星数不是实时指标，没必要每次打开「关于」都请求一次。
        static let lifetime: TimeInterval = 24 * 60 * 60
    }

    /// 取星标数：优先用缓存，过期或没有才请求。
    ///
    /// 失败不打扰用户——有旧值就继续用（别让数字忽然消失），没有就保持 nil，
    /// 「关于」页那一行只会少一个数字，不会多一条错误。
    func loadStarCount() async {
        let defaults = UserDefaults.group
        let cachedAt = defaults.object(forKey: StarCache.fetchedAt) as? Date
        let cached = defaults.object(forKey: StarCache.count) as? Int

        if let cachedAt, let cached, Date().timeIntervalSince(cachedAt) < StarCache.lifetime {
            starCount = cached
            return
        }

        if let fresh = try? await githubChecker.fetchStarCount() {
            starCount = fresh
            defaults.set(fresh, forKey: StarCache.count)
            defaults.set(Date(), forKey: StarCache.fetchedAt)
        } else if let cached {
            starCount = cached
        }
    }
    
    // 关闭更新提示。
    // 只关窗，**不清空检查结果**：清空会让「关于」页的状态行在关窗后退回「尚未检查」，
    // 把用户刚拿到的信息抹掉；再用「查看详情…」打开时也会看到一张空白的卡片。
    func dismissUpdateSheet() {
        showUpdateSheet = false
    }

    /// 打开更新弹窗展示上次的检查结果，不重新发起检查。
    func showUpdateDetails() {
        showUpdateSheet = true
    }
      
    // 检查更新
    func checkForUpdates(force: Bool = false) async {
        guard !isChecking, !isDownloading else { return }
        isChecking = true
        updateError = nil
        availableUpdate = nil
        isUpToDate = false
        showUpdateSheet = true

        defer { isChecking = false }

        switch await githubChecker.checkForUpdate(currentVersion: currentVersion) {
        case .failed(let reason):
            // 真失败。从此不再和「已是最新」共用 updateError，弹窗标题才对得上内容。
            updateError = reason

        case .upToDate:
            // 单独置位。updateError 保持 nil，弹窗因此会走到它原本走不到的 else 分支，
            // 显示作者早就写好、却从未显示过的绿色「Up to Date」卡片。
            isUpToDate = true

        case .updateAvailable(let release):
            // 检查用户是否忽略了此版本
            if !force && preferences.isVersionIgnored(release.version) {
                updateError = String(format: AppLocalization.localized("Version %@ is ignored"), release.version)
                return
            }
            availableUpdate = release
        }
    }
    
    // MARK: - 下载和安装方法

    func downloadAndInstallUpdate() async {
        guard !isDownloading else { return }
        updateError = nil
        print("start downloadAndInstallUpdate")

        // App Store 构建：禁止自更新，引导用户去 Mac App Store
        guard !isAppStoreBuild else {
            showAppStoreUpdateAlert()
            return
        }

        guard let release = availableUpdate else {
            updateError = AppLocalization.localized("No update is available.")
            print("没有可用的更新")
            return
        }
        
        // 查找 .app.zip 附件
        guard let appZipAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".app.zip") }) else {
            updateError = AppLocalization.localized("No .app.zip application package was found.")
            print("没有可用的更新")
            return
        }
        
        isDownloading = true
        downloadProgress = 0
        var downloadedURL: URL?
        var extractedAppURL: URL?
        defer {
            isDownloading = false
            if let downloadedURL { try? FileManager.default.removeItem(at: downloadedURL) }
            if let extractedAppURL { try? FileManager.default.removeItem(at: extractedAppURL.deletingLastPathComponent()) }
        }
        
        do {
            // 1. 下载 ZIP 文件
            let archiveURL = try await downloadAsset(asset: appZipAsset)
            downloadedURL = archiveURL
            
            // 2. 解压到临时目录
            let appURL = try await extractAppZip(zipURL: archiveURL)
            extractedAppURL = appURL
            
            // 3. 安装应用到应用程序目录
            try await installApplication(appURL: appURL)
            
            // 只有完整安装成功才显示完成提示；临时文件由 defer 统一清理。
            showInstallationCompleteAlert()
            
        } catch {
            updateError = String(format: AppLocalization.localized("Installation failed: %@"), error.localizedDescription)
        }
        
    }

    func downloadAsset(asset: GitHubRelease.Asset) async throws -> URL {
        print("start downloadAsset:\(asset.browserDownloadUrl)")
        let tempDir = FileManager.default.temporaryDirectory
        let downloadURL = tempDir.appendingPathComponent("\(UUID().uuidString)-\(asset.name)")
        
        var request = URLRequest(url: URL(string: asset.browserDownloadUrl)!)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        
        let downloadFailedMessage = AppLocalization.localized("Download failed")
        
        // 使用 AsyncThrowingStream 来包装下载进度和结果
        return try await withCheckedThrowingContinuation { continuation in
            // Stream bytes and write to destination file
            let session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
            let task = session.downloadTask(with: request) { tempURL, response, error in

                print("start do")
                if let error = error {
                    print("downn error")
                    continuation.resume(throwing: error)
                    return
                }

                guard let tempURL = tempURL,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200
                else {
                    continuation.resume(throwing: DownloadError.downloadFailed(downloadFailedMessage))
                    print("downn error")
                    return
                }

                do {
                    // 移动文件到目标位置
                    try? FileManager.default.removeItem(at: downloadURL)
                    try FileManager.default.moveItem(at: tempURL, to: downloadURL)
                    print("download url: \(downloadURL.path)")
                    continuation.resume(returning: downloadURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            task.resume()
        }
    }

    // 关联对象键
    private var DownloadDelegateKey: UInt8 = 0

    // MARK: - 解压 APP Zip 文件

    /// 解压不占用主线程；持续读取错误输出，避免等待退出时管道写满死锁。
    func extractAppZip(zipURL: URL) async throws -> URL {
        let extractionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TRClick-extraction-\(UUID().uuidString)", isDirectory: true)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let fileManager = FileManager.default
                    try fileManager.createDirectory(at: extractionDir, withIntermediateDirectories: true)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                    process.arguments = ["-q", "-o", zipURL.path, "-d", extractionDir.path]
                    process.standardOutput = FileHandle.nullDevice
                    let errorPipe = Pipe()
                    process.standardError = errorPipe
                    try process.run()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let detail = String(data: errorData, encoding: .utf8) ?? AppLocalization.localized("Unknown error")
                        throw InstallationError.zipExtractionFailed(String(format: AppLocalization.localized("Extraction failed: %@"), detail))
                    }
                    let contents = try fileManager.contentsOfDirectory(at: extractionDir, includingPropertiesForKeys: nil)
                    guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
                        throw InstallationError.noAppFound(AppLocalization.localized("No .app application was found in the ZIP file."))
                    }
                    continuation.resume(returning: appURL)
                } catch {
                    try? FileManager.default.removeItem(at: extractionDir)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 请求文件夹权限
    @MainActor
    private func requestApplicationsFolderAccess() async throws {
        let openPanel = NSOpenPanel()
        openPanel.message = AppLocalization.localized("TRClick needs permission to install the update into your Applications folder.")
        openPanel.prompt = AppLocalization.localized("Grant Permission")
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first

        let response = await openPanel.begin()
        
        guard response == .OK, let selectedURL = openPanel.url else {
            throw InstallationError.permissionDenied(AppLocalization.localized("The user cancelled authorization."))
        }

        // 验证用户是否选择了正确的文件夹
        let applicationsURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first!
        guard selectedURL.path == applicationsURL.path else {
            throw InstallationError.permissionDenied(AppLocalization.localized("Please select the correct Applications folder."))
        }
    }
    // MARK: - 安装应用到应用程序目录
    /// 新包先复制到同卷暂存目录并校验，再由文件系统替换旧版。
    /// applicationsDirectory 可指定临时目录，以便测试不会触碰已安装的应用。
    func installApplication(appURL: URL, applicationsDirectory: URL? = nil) async throws {
        let fileManager = FileManager.default
        let applicationsURL = applicationsDirectory
            ?? fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TRClick"
        let destinationAppURL = applicationsURL.appendingPathComponent("\(appName).app")
        if applicationsDirectory == nil, !fileManager.isWritableFile(atPath: applicationsURL.path) {
            try await requestApplicationsFolderAccess()
        }
        let stagingDir = applicationsURL.appendingPathComponent(".TRClick-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDir) }
        let stagedApp = stagingDir.appendingPathComponent(destinationAppURL.lastPathComponent)
        try fileManager.copyItem(at: appURL, to: stagedApp)
        guard let bundle = Bundle(url: stagedApp),
              bundle.bundleIdentifier == (Bundle.main.bundleIdentifier ?? "com.tfcup.TRClick"),
              let executable = bundle.executableURL,
              fileManager.isExecutableFile(atPath: executable.path) else {
            throw InstallationError.invalidAppBundle(AppLocalization.localized("The application bundle is invalid or damaged."))
        }
        if fileManager.fileExists(atPath: destinationAppURL.path) {
            _ = try fileManager.replaceItemAt(destinationAppURL, withItemAt: stagedApp, options: .usingNewMetadataOnly)
        } else {
            try fileManager.moveItem(at: stagedApp, to: destinationAppURL)
        }
    }

    // MARK: - App Store 更新引导

    /// App Store 构建：提示用户通过 Mac App Store 更新
    private func showAppStoreUpdateAlert() {
        let alert = NSAlert()
        alert.messageText = AppLocalization.localized("Update via Mac App Store")
        alert.informativeText = AppLocalization.localized("TRClick is installed from the Mac App Store. Please update it from the App Store.")
        alert.addButton(withTitle: AppLocalization.localized("Open App Store"))
        alert.addButton(withTitle: AppLocalization.localized("Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "macappstore://")!)
        }
    }

    // MARK: - 显示安装完成提示

    private func showInstallationCompleteAlert() {
        let alert = NSAlert()
        alert.messageText = AppLocalization.localized("Update Installed")
        alert.informativeText = AppLocalization.localized("The application has been updated successfully. Restart the app to finish the update.")
        alert.addButton(withTitle: AppLocalization.localized("Restart Now"))
        alert.addButton(withTitle: AppLocalization.localized("Restart Later"))
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // 启动新应用并退出当前应用
            launchNewApplicationAndExit()
        }
    }

    // MARK: - 启动新应用并退出

    private func launchNewApplicationAndExit() {
        let fileManager = FileManager.default
        let applicationsURL = fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first!
        let currentAppName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TRClick"
        let newAppURL = applicationsURL.appendingPathComponent("\(currentAppName).app")
        
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: newAppURL, configuration: configuration) { _, error in
            if error != nil {
                print("启动新应用失败，可能需要手动启动")
            }
            // 无论如何都退出当前应用（切回主线程）
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    // 忽略当前可用更新
    func ignoreCurrentUpdate() {
        if let version = availableUpdate?.version {
            preferences.ignoreVersion(version)
            availableUpdate = nil
        }
    }
    
    /// 统一的仓库地址拼接：owner/repo 来自 init，不在各处再硬编码一遍。
    private func openGitHub(_ path: String = "") {
        guard let url = URL(string: "https://github.com/\(owner)/\(repo)\(path)") else { return }
        NSWorkspace.shared.open(url)
    }

    // 打开GitHub发布页面
    func openReleasesPage() { openGitHub("/releases") }

    /// 打开仓库主页（「关于」页的「加星」走这里）。
    func openRepositoryPage() { openGitHub() }

    /// 打开 Issues 列表（「关于」页的「反馈问题」走这里）。
    func openIssuesPage() { openGitHub("/issues") }
    
    // MARK: - 错误类型

    enum DownloadError: LocalizedError {
        case downloadFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .downloadFailed(let message):
                return message
            }
        }
    }

    nonisolated enum InstallationError: LocalizedError {
        case zipExtractionFailed(String)
        case noAppFound(String)
        case invalidAppBundle(String)
        case permissionDenied(String)
        
        var errorDescription: String? {
            switch self {
            case .zipExtractionFailed(let message):
                return message
            case .noAppFound(let message):
                return message
            case .invalidAppBundle(let message):
                return message
            case .permissionDenied(let message):
                return message
            }
        }
    }
}
