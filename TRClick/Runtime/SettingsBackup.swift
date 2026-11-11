//
//  SettingsBackup.swift
//  TRClick
//
//  设置备份文件模型：Export / Import 共用的版本化 JSON 结构。
//

import Foundation

/// TRClick 设置备份。
///
/// 只包含可跨机器迁移的配置。模板和默认应用只记录路径，导入时再检查是否存在。
struct SettingsBackup: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var exportedAt: Date
    var apps: [App]
    var actions: [Action]
    var newFiles: [FileTemplate]
    var preferences: Preferences

    struct App: Codable {
        var id: String
        var path: String
        var itemName: String
        var inheritFromGlobalArguments: Bool
        var inheritFromGlobalEnvironment: Bool
        var arguments: [String]
        var environment: [String: String]
        var opensNewInstance: Bool
        var showInToolbar: Bool
        var showInContextMenu: Bool
        var opensContainingDir: Bool?
    }

    struct Action: Codable {
        var id: String
        var enabled: Bool
        var idx: Int
    }

    struct FileTemplate: Codable {
        var id: String
        var ext: String
        var name: String
        var enabled: Bool
        var idx: Int
        var icon: String
        var openAppPath: String?
        var templatePath: String?
    }

    struct Preferences: Codable {
        var foldAppsMenu: Bool
        var foldActionsMenu: Bool
        var foldNewFileMenu: Bool
        var appIconStyle: Int
        var showMenuBarExtra: Bool
        var launchAtLogin: Bool
    }
}

// MARK: - Export

@MainActor
extension SettingsBackup {
    init(appState: AppState, defaults: UserDefaults = .group) {
        schemaVersion = Self.currentSchemaVersion
        exportedAt = Date()
        apps = appState.apps.map { App($0) }
        actions = appState.actions.map { Action($0) }
        newFiles = appState.newFiles.map { FileTemplate($0) }
        // 读 AppState 的实际值，而不是 UserDefaults 的原始值：@AppStorage 的
        // 默认值不会写进 UserDefaults，未改过的 foldNewFileMenu 用
        // bool(forKey:) 会被读成 false。
        preferences = Preferences(
            foldAppsMenu: appState.foldAppsMenu,
            foldActionsMenu: appState.foldActionsMenu,
            foldNewFileMenu: appState.foldNewFileMenu,
            appIconStyle: appState.appIconStyle,
            showMenuBarExtra: defaults.object(forKey: Key.showMenuBarExtra) as? Bool ?? true,
            launchAtLogin: LaunchAtLogin.isEnabled
        )
    }
}

@MainActor
extension SettingsBackup.App {
    init(_ app: OpenWithApp) {
        id = app.id
        path = app.url.path
        itemName = app.itemName
        inheritFromGlobalArguments = app.inheritFromGlobalArguments
        inheritFromGlobalEnvironment = app.inheritFromGlobalEnvironment
        arguments = app.arguments
        environment = app.environment
        opensNewInstance = app.opensNewInstance
        showInToolbar = app.showInToolbar
        showInContextMenu = app.showInContextMenu
        opensContainingDir = app.opensContainingDir
    }
}

@MainActor
extension SettingsBackup.Action {
    init(_ action: RCAction) {
        id = action.id
        enabled = action.enabled
        idx = action.idx
    }
}

@MainActor
extension SettingsBackup.FileTemplate {
    init(_ file: NewFile) {
        id = file.id
        ext = file.ext
        name = file.name
        enabled = file.enabled
        idx = file.idx
        icon = file.icon
        openAppPath = file.openApp?.path
        templatePath = file.template?.path
    }
}

// MARK: - Import

@MainActor
extension SettingsBackup.App {
    /// 应用路径不存在时返回 nil，由调用方统计并提示。
    func toModel() -> OpenWithApp? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var app = OpenWithApp(id: id, appURL: URL(fileURLWithPath: path))
        app.itemName = itemName
        app.inheritFromGlobalArguments = inheritFromGlobalArguments
        app.inheritFromGlobalEnvironment = inheritFromGlobalEnvironment
        app.arguments = arguments
        app.environment = environment
        app.opensNewInstance = opensNewInstance
        app.showInToolbar = showInToolbar
        app.showInContextMenu = showInContextMenu
        app.opensContainingDir = opensContainingDir
        return app
    }
}

@MainActor
extension SettingsBackup.FileTemplate {
    /// 模板或默认打开方式指向的文件不存在时清空，让新建文件回退到内置模板。
    func toModel() -> NewFile {
        var file = NewFile(ext: ext, name: name, enabled: enabled, idx: idx, icon: icon, id: id)
        if let templatePath, FileManager.default.fileExists(atPath: templatePath) {
            file.template = URL(fileURLWithPath: templatePath)
        }
        if let openAppPath, FileManager.default.fileExists(atPath: openAppPath) {
            file.openApp = URL(fileURLWithPath: openAppPath)
        }
        return file
    }
}

@MainActor
extension SettingsBackup {
    /// 按备份里的顺序和启用状态重建动作，并补齐备份中缺失的内置动作。
    ///
    /// 动作集合由代码维护，设置页没有增删入口；旧备份可能不包含后来新增的动作，
    /// 直接采用备份会导致新动作消失，所以缺失项按默认状态补在末尾。
    static func resolveActions(_ actions: [Action]) -> [RCAction] {
        let canonical = RCAction.all.sorted { $0.idx < $1.idx }
        var remaining = Dictionary(uniqueKeysWithValues: canonical.map { ($0.id, $0) })
        var result: [RCAction] = []

        for entry in actions.sorted(by: { $0.idx < $1.idx }) {
            guard var action = remaining.removeValue(forKey: entry.id) else { continue }
            action.enabled = entry.enabled
            result.append(action)
        }
        result.append(contentsOf: canonical.filter { remaining[$0.id] != nil })

        return result.enumerated().map { index, action in
            var action = action
            action.idx = index
            return action
        }
    }
}

@MainActor
extension SettingsBackup.Preferences {
    func apply(to defaults: UserDefaults = .group) {
        defaults.set(foldAppsMenu, forKey: "foldAppsMenu")
        defaults.set(foldActionsMenu, forKey: "foldActionsMenu")
        defaults.set(foldNewFileMenu, forKey: "foldNewFileMenu")
        defaults.set(appIconStyle, forKey: "appIconStyle")
        defaults.set(showMenuBarExtra, forKey: Key.showMenuBarExtra)

        if LaunchAtLogin.isEnabled != launchAtLogin {
            LaunchAtLogin.isEnabled = launchAtLogin
        }
    }
}
