//
//  ActionService.swift
//  TRClick
//
//  文件操作 / 动作执行服务。从原 AppDelegate 迁移而来，是主 app 的"动作执行层"。
//  依赖 AppState（只读状态）、PermissionService 与删除确认（经协议注入，可 mock 单测）。
//  注意：第一版不过度拆分，用私有方法 + MARK 分组（FileActions / AppActions / FinderActions / SystemActions）。
//

import AppKit
import ApplicationServices
import Foundation
import os.log

@MainActor
final class ActionService {
    @AppLog(category: "ActionService")
    private var logger

    private let state: ActionStateProviding
    private let permission: PermissionProviding
    private let confirmation: DeleteConfirmationProviding

    init(state: ActionStateProviding, permission: PermissionProviding, confirmation: DeleteConfirmationProviding) {
        self.state = state
        self.permission = permission
        self.confirmation = confirmation
    }

    // MARK: - SystemActions

    /// 复制路径到剪贴板
    func copyPath(_ target: [String]) {
        if let dirPath = target.first {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(dirPath, forType: .string)
        }
    }

    /// 复制文件名（不含路径）到剪贴板
    func copyFileName(_ target: [String]) {
        guard let path = target.first else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !name.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(name, forType: .string)
    }

    // MARK: - AppActions

    /// 用指定应用打开选中文件/目录（沙盒门控：先 hasAccess，失败兜底再授权重试）
    func openApp(rid: String, target: [String]) async {
        guard let rcitem = state.getAppItem(rid: rid) else {
            logger.warning("when openapp, but not have app \(rid)")
            return
        }

        let appUrl = rcitem.url
        logger.debug("openApp: rid=\(rid) app=\(appUrl.path) target=\(target) opensNewInstance=\(rcitem.opensNewInstance)")

        // 通过共享目标解析处理「选中文件时打开所在目录」选项
        for resolved in AppPresets.resolveOpenTargets(
            appPath: appUrl.path, explicit: rcitem.opensContainingDir, targetPaths: target
        ) {
            await openWithApp(
                resolved.url, appUrl: appUrl, opensNewInstance: rcitem.opensNewInstance,
                arguments: rcitem.arguments, environment: rcitem.environment
            )
        }
    }

    private func openWithApp(
        _ url: URL, appUrl: URL, opensNewInstance: Bool,
        arguments: [String] = [], environment: [String: String] = [:]
    ) async {
        let logger = self.logger  // 捕获 Sendable logger，供完成回调使用
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let accessURL = (exists && isDir.boolValue) ? url : url.deletingLastPathComponent()

        // 门控先行：未授权先弹窗，避免"只是打开一个文件"也要用户授权整个父目录的弹窗偏重
        if !permission.hasAccess(to: accessURL) {
            guard await permission.promptForPermission(for: accessURL) != nil else {
                logger.warning("用户取消授权，跳过打开：\(url.path)")
                return
            }
        }

        let config = NSWorkspace.OpenConfiguration()
        // 以新实例打开（浏览器类 app 会新开窗口而非新 tab）
        config.createsNewApplicationInstance = opensNewInstance
        config.arguments = arguments
        config.environment = environment
        NSWorkspace.shared.open([url], withApplicationAt: appUrl, configuration: config) { [weak self] runningApp, error in
            guard let self else { return }
            if let error {
                // 失败兜底：再弹授权并重试一次
                Task { @MainActor in
                    await self.openRetryAfterPermission(
                        url: url, appUrl: appUrl, accessURL: accessURL,
                        opensNewInstance: opensNewInstance, arguments: arguments,
                        environment: environment, firstError: error
                    )
                }
            } else if let runningApp {
                logger.debug("Successfully opened with application: \(runningApp.localizedName ?? "Unknown")")
            }
        }
    }

    private func openRetryAfterPermission(
        url: URL, appUrl: URL, accessURL: URL, opensNewInstance: Bool,
        arguments: [String], environment: [String: String], firstError: Error
    ) async {
        let logger = self.logger  // 捕获 Sendable logger
        guard await permission.promptForPermission(for: accessURL) != nil else {
            logger.error("打开失败且用户取消授权：\(url.path) — \(firstError.localizedDescription)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = opensNewInstance
        config.arguments = arguments
        config.environment = environment
        NSWorkspace.shared.open([url], withApplicationAt: appUrl, configuration: config) { _, retryError in
            if let retryError {
                logger.error("重试打开仍失败：\(url.path) — \(retryError.localizedDescription)")
            }
        }
    }

    // MARK: - FileActions

    /// 动作分发入口
    func actionHandler(rid: String, target: [String], trigger: String, optionKeyPressed: Bool = false) async {
        guard let rcitem = state.getActionItem(rid: rid) else {
            logger.warning("when actionHandler, but not have action \(rid)")
            return
        }

        switch rcitem.id {
        case "copy-path":
            copyPath(target)
        case "copy-file-name":
            copyFileName(target)
        case "delete-direct":
            await deleteFoldorFile(target, trigger, optionKeyPressed: optionKeyPressed)
        default:
            logger.warning("no action id matched")
        }
    }

    func deleteFoldorFile(_ target: [String], _ trigger: String, optionKeyPressed: Bool = false) async {
        logger.info("---- deleteFoldorFile trigger:\(trigger) option:\(optionKeyPressed)")
        let fm = FileManager.default

        if trigger == "ctx-container" {
            let alert = NSAlert()
            alert.messageText = AppLocalization.localized("Warning")
            alert.informativeText = AppLocalization.localized("The current folder cannot be deleted. Please select files or subfolders instead.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: AppLocalization.localized("OK"))
            alert.runModal()
            return
        }

        var pathsToDelete: [String] = []
        for path in target {
            if Utils.isProtectedFolder(path) {
                let alert = NSAlert()
                alert.messageText = AppLocalization.localized("Warning")
                alert.informativeText = String(format: AppLocalization.localized("Protected system folders cannot be deleted: %@"), path)
                alert.alertStyle = .warning
                alert.addButton(withTitle: AppLocalization.localized("OK"))
                alert.runModal()
                logger.warning("试图删除受保护的系统文件夹，操作已被阻止：\(path)")
                continue
            }

            pathsToDelete.append(path)
        }

        guard !pathsToDelete.isEmpty else { return }

        // 权限直通（不沙盒），这里的循环不会拦截任何路径；保留结构是为了
        // 确认框里的条目数仍然等于"确认后真的会被删掉的数量"。
        var authorized: [String] = []
        for decodedPath in pathsToDelete {
            let dirURL = URL(fileURLWithPath: decodedPath).deletingLastPathComponent()
            if !permission.hasAccess(to: dirURL) {
                guard await permission.promptForPermission(for: dirURL) != nil else {
                    logger.warning("用户取消授权，跳过删除：\(decodedPath)")
                    continue
                }
                guard permission.hasAccess(to: dirURL) else {
                    logger.warning("授权未覆盖目标目录，跳过删除：\(decodedPath)")
                    continue
                }
            }
            authorized.append(decodedPath)
        }

        guard !authorized.isEmpty else { return }

        // 绕过废纸篓的删除默认必须确认；按住 Option 点击是唯一跳过确认的方式。
        if !optionKeyPressed {
            guard await confirmation.confirmPermanentDelete(paths: authorized) else {
                logger.info("用户取消了删除确认，共 \(authorized.count) 项未删除")
                return
            }
        }

        for decodedPath in authorized {
            do { try fm.removeItem(atPath: decodedPath) }
            catch { logger.error("delete \(decodedPath) file run error \(error)") }
        }
    }

    // MARK: - NewFileActions

    func createFile(rid: String, target: [String]) async {
        guard let dirPath = targetDirectoryForNewFile(target) else {
            logger.warning("when createFile, but not have target directory")
            return
        }

        let dirURL = URL(fileURLWithPath: dirPath)

        // 确保有目标目录的访问权限
        if !permission.hasAccess(to: dirURL) {
            guard await permission.promptForPermission(for: dirURL) != nil else {
                logger.warning("用户取消授权，跳过创建文件")
                return
            }
        }

        if rid == NewFileMenuItem.customFileId {
            let filePath = getUniqueFilePath(dir: dirPath, ext: "")
            let fileURL = URL(fileURLWithPath: filePath)
            do {
                try Data().write(to: fileURL)
                logger.info("created editable file: \(fileURL.path)")
                revealInFinderAndRename(fileURL)
            } catch {
                logger.error("create editable file error: \(error.localizedDescription)")
            }
            return
        }

        guard let rcitem = state.getFileType(rid: rid) else {
            logger.warning("when createFile, but not have fileType \(rid) ")
            return
        }

        let ext = NewFile.normalizedExtension(rcitem.ext)
        logger.info("create file dir:\(dirPath) -- ext \(ext)")
        let filePath = getUniqueFilePath(dir: dirPath, ext: ext)
        let fileURL = URL(fileURLWithPath: filePath)

        do {
            let fileManager = FileManager.default

            if let templateUrl = rcitem.template {
                try fileManager.copyItem(at: templateUrl, to: fileURL)
                logger.info("已成功复制模板到目标路径：\(fileURL.path)")
            } else {
                let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
                if let defaultTemplateURL = Bundle.main.url(forResource: "template", withExtension: cleanExt) {
                    logger.info("使用模板创建文件，模板路径：\(defaultTemplateURL.path)")
                    try fileManager.copyItem(at: defaultTemplateURL, to: fileURL)
                    logger.info("已成功复制模板到目标路径：\(fileURL.path)")
                } else {
                    // 这些格式需要完整的文档包，不能用零字节文件代替。
                    if ["docx", "pptx", "xlsx", "pages", "key", "numbers"].contains(cleanExt.lowercased()) {
                        let alert = NSAlert()
                        alert.messageText = AppLocalization.localized("Template Required")
                        alert.informativeText = String(format: AppLocalization.localized("Choose a valid %@ template in Settings > New File before creating this document."), ext)
                        alert.addButton(withTitle: AppLocalization.localized("OK"))
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                        return
                    }
                    logger.warning("模板文件不存在：\(ext)")
                    try Data().write(to: fileURL)
                }
            }
            if let appURL = rcitem.openApp {
                await openWithApp(fileURL, appUrl: appURL, opensNewInstance: false)
            } else {
                revealInFinderAndRename(fileURL)
            }
        } catch let error as NSError {
            switch error.domain {
            case NSCocoaErrorDomain:
                switch error.code {
                case NSFileNoSuchFileError:
                    logger.error("文件不存在：\(filePath)")
                case NSFileWriteOutOfSpaceError:
                    logger.error("磁盘空间不足")
                case NSFileWriteNoPermissionError:
                    logger.error("没有写入权限：\(filePath)")
                default:
                    logger.error("创建文件错误：\(error.localizedDescription) (错误码：\(error.code))")
                }
            default:
                logger.error("未处理的错误：\(error.localizedDescription) (错误码：\(error.code))")
            }
        }
    }

    // MARK: - 辅助

    /// 生成目录内唯一的文件名（避免重名冲突）
    func getUniqueFilePath(dir: String, ext: String) -> String {
        let fileManager = FileManager.default
        let dirURL = URL(fileURLWithPath: dir)
        let ext = NewFile.normalizedExtension(ext)
        let baseFileName = AppLocalization.localized("Untitled")
        var filePath = dirURL.appendingPathComponent("\(baseFileName)\(ext)").path
        var counter = 1

        while fileManager.fileExists(atPath: filePath) {
            let newFileName = "\(baseFileName)\(counter)"
            filePath = dirURL.appendingPathComponent("\(newFileName)\(ext)").path
            counter += 1
        }

        return filePath
    }

    /// 解析新建文件的目标目录（目录直接用；文件取父目录）
    private func targetDirectoryForNewFile(_ target: [String]) -> String? {
        guard let path = target.first else { return nil }
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return path
            }
            return URL(fileURLWithPath: path).deletingLastPathComponent().path
        }

        return path
    }

    /// 在 Finder 中选中新文件并触发重命名（需要辅助功能权限）
    private func revealInFinderAndRename(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])

        guard AXIsProcessTrusted() else {
            // 等 Finder 完成激活和选中再弹提示，避免提示窗口被 Finder 抢到后面。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.presentAccessibilityHintIfNeeded()
            }
            return
        }

        // 权限可用时重新武装一次性提示：用户之后撤销权限，还能再收到一次提醒。
        UserDefaults.group.set(false, forKey: Key.didShowRenamePermissionHint)
        waitForFinderThenRename(fileURL)
    }

    /// 缺少辅助功能权限时只提示一次，之后静默跳过自动重命名。
    private func presentAccessibilityHintIfNeeded() {
        let defaults = UserDefaults.group
        guard !defaults.bool(forKey: Key.didShowRenamePermissionHint) else {
            logger.debug("Accessibility permission still missing; auto-rename skipped")
            return
        }
        defaults.set(true, forKey: Key.didShowRenamePermissionHint)

        let alert = NSAlert()
        alert.messageText = AppLocalization.localized("Auto-Rename Needs Permission")
        alert.informativeText = String(
            format: AppLocalization.localized(
                "TRClick needs \"%@\" permission to rename a newly created file automatically. Enable it for the TRClick app in System Settings > %@."
            ),
            SystemSettingsNaming.accessibilitySection,
            SystemSettingsNaming.privacySecuritySection
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: AppLocalization.localized("Open Settings"))
        alert.addButton(withTitle: AppLocalization.localized("Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionChecker.openAccessibilitySettings()
        }
    }

    /// 等 Finder 真正成为前台并稳定后再发 Return。
    ///
    /// 原来的固定 0.35s + 0.25s 延时在慢目录或 Finder 响应较慢时会抢跑，
    /// 表现为“有时进入重命名、有时没有”。这里改成轮询前台应用，最多等 2 秒。
    private func waitForFinderThenRename(
        _ fileURL: URL,
        deadline: Date = .now.addingTimeInterval(2),
        activate: Bool = true
    ) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            // 激活和选中不是同一时刻完成，留一点稳定时间再触发重命名。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.postReturnKey()
            }
            return
        }

        guard Date() < deadline else {
            logger.warning("Finder did not become active; auto-rename skipped for \(fileURL.path)")
            return
        }

        // 只激活一次，之后单纯轮询，避免每 50ms 重复调用 activate。
        if activate {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForFinderThenRename(fileURL, deadline: deadline, activate: false)
        }
    }

    private func postReturnKey() {
        let keyCodeReturn: CGKeyCode = 36
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeReturn, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeReturn, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
