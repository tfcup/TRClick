//
//  RCBase.swift
//  TRClick
//
//  Created by 李旭 on 2024/9/26.
//
import AppKit
import Foundation

protocol RCBase: Hashable, Identifiable, Codable {
    var id: String { get }
}

struct OpenWithApp: @MainActor RCBase {
    var id: String

    init(id: String = UUID().uuidString, appURL url: URL) {
        self.id = id
        self.url = url
        itemName = url.deletingPathExtension().lastPathComponent
    }

    var url: URL
    var itemName: String
    var inheritFromGlobalArguments = true
    var inheritFromGlobalEnvironment = true
    var arguments: [String] = []
    var environment: [String: String] = [:]
    /// 是否以新实例（新窗口）打开（对应 NSWorkspace.OpenConfiguration.createsNewApplicationInstance）
    var opensNewInstance = false
    /// 是否在 Finder 自定义工具栏菜单中显示
    var showInToolbar = true
    /// 是否在右键菜单中显示
    var showInContextMenu = true
    /// 选中文件交给该应用时是否改为打开所在目录（终端类行为）
    /// `nil` = 未手动设置，运行时按预设终端分类（AppPresets.terminalBundleIDs）兜底
    var opensContainingDir: Bool? = nil

    nonisolated var appName: String {
        FileManager.default.displayName(atPath: url.path)
    }

    nonisolated var name: String {
        itemName.isEmpty ? appName : itemName
    }
}

@MainActor
extension OpenWithApp {
    init?(bundleIdentifier identifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return nil
        }
        self.init(appURL: url)
    }

    static var vscode: OpenWithApp? {
        // 尝试多个 VS Code 变体的 bundle identifier
        let identifiers = [
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
        ]
        if let id = identifiers.first(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return OpenWithApp(appURL: url)
        }
        // 回退：搜索常见路径
        let commonPaths = [
            "/Applications/Visual Studio Code.app",
            "/Applications/Visual Studio Code - Insiders.app",
            NSHomeDirectory() + "/Applications/Visual Studio Code.app",
        ]
        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return OpenWithApp(appURL: URL(fileURLWithPath: path))
            }
        }
        return nil
    }
    static let terminal = OpenWithApp(bundleIdentifier: "com.apple.Terminal")
    static var defaultApps: [OpenWithApp] {
        [
            .terminal,
            vscode,
        ].compactMap { $0 }
    }
}

struct RCAction: @MainActor RCBase {
    static func == (lhs: RCAction, rhs: RCAction) -> Bool {
        lhs.id == rhs.id
    }

    var id: String

    var name: String
    var enabled = true
    var idx: Int
    var icon: String

    init(id: String, name: String, enabled: Bool = true, idx: Int, icon: String) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.idx = idx
        self.icon = icon
    }
}


extension RCAction {

    static let copyPath = RCAction(id: "copy-path", name: "Copy Path", enabled: true, idx: 0, icon: "doc.on.doc")
    static let copyFileName = RCAction(id: "copy-file-name", name: "Copy File Name", enabled: true, idx: 1, icon: "doc.text")
    static let deleteDirect = RCAction(id: "delete-direct", name: "Delete Direct", enabled: true, idx: 2, icon: "trash")

    static let all: [RCAction] = [.copyPath, .copyFileName, .deleteDirect]
}

// New File Type
struct NewFile: @MainActor RCBase {
    static func == (lhs: NewFile, rhs: NewFile) -> Bool {
        lhs.id == rhs.id
    }

    var ext: String
    var name: String
    var enabled = true
    var idx: Int
    var icon: String
    var id: String
    var openApp: URL?
    var template: URL?

    init(ext: String, name: String, enabled: Bool = true, idx: Int, icon: String = "document", id: String = UUID().uuidString) {
        self.ext = ext
        self.name = name
        self.enabled = enabled
        self.idx = idx
        self.icon = icon
        self.id = id
    }
}


extension NewFile {
    static let all: [NewFile] = [.txt, .md, .json, .docx, .pptx, .xlsx, .pages, .key, .numbers]

    // `id` 必须逐字对上 `NewFileTypeEntity.createDefaultFileTypes()`。
    // 这几个字面量原本不传 id，于是全都取了 init 的默认值 `UUID()`——「恢复默认」
    // 写回数据库的就是一排随机 id，和种子数据对不上，`displayName` 查译文也就没了依据。
    //
    // icon 字段为 SF Symbol 名称，作为 NSWorkspace 获取失败时的 fallback
    static let json = NewFile(ext: ".json", name: "JSON", enabled: false, idx: 0, icon: "curlybraces", id: "json")
    static let txt = NewFile(ext: ".txt", name: "TXT", idx: 1, icon: "doc.text", id: "txt")
    static let md = NewFile(ext: ".md", name: "Markdown", idx: 2, icon: "doc.richtext", id: "md")
    static let docx = NewFile(ext: ".docx", name: "DOCX", idx: 3, icon: "doc.richtext.fill", id: "docx")
    static let pptx = NewFile(ext: ".pptx", name: "PPTX", idx: 4, icon: "rectangle.on.rectangle.fill", id: "pptx")
    static let xlsx = NewFile(ext: ".xlsx", name: "XLSX", idx: 5, icon: "tablecells", id: "xlsx")
    static let pages = NewFile(ext: ".pages", name: "Pages", idx: 6, icon: "doc.richtext", id: "pages")
    static let key = NewFile(ext: ".key", name: "Keynote", idx: 7, icon: "rectangle.on.rectangle", id: "key")
    static let numbers = NewFile(ext: ".numbers", name: "Numbers", idx: 8, icon: "tablecells", id: "numbers")
}

extension NewFile {
    /// 本地化显示名称。
    ///
    /// 内置类型按 id 取译文；用户自己添加的类型走 `name`，用户填的名字不该被翻译。
    /// 和 `RCAction.displayName` 是同一个模式——NewFile
    /// 此前是唯一没有这个属性的模型，所以「新建文件」子菜单在每个语言下都是英文原文。
    ///
    /// JSON / TXT / Markdown / Pages / Keynote / Numbers 刻意不进字符串目录：它们是
    /// 格式缩写和 Apple 产品名，各语言都不翻译，`localized` 查不到就回落到 key 本身，
    /// 正好是想要的显示文本。只有三个 Office 格式有各语言通用的描述性叫法。
    var displayName: String {
        switch id {
        case "json": return AppLocalization.localized("JSON")
        case "txt": return AppLocalization.localized("TXT")
        case "md": return AppLocalization.localized("Markdown")
        case "docx": return AppLocalization.localized("DOCX")
        case "pptx": return AppLocalization.localized("PPTX")
        case "xlsx": return AppLocalization.localized("XLSX")
        case "pages": return AppLocalization.localized("Pages")
        case "key": return AppLocalization.localized("Keynote")
        case "numbers": return AppLocalization.localized("Numbers")
        default: return name
        }
    }
}

// MARK: - Menu Item Models for Extension Communication

/// Menu item for opening files with external applications
struct AppMenuItem: Codable {
    let id: String
    let name: String
    let icon: String
    let tag: Int
    let appURL: String?  // 应用路径，用于获取应用图标
    /// 是否以新实例打开（浏览器类 app 新开窗口而非新 tab）。
    /// 扩展端快链路直接打开 App 时需要这个字段。
    let opensNewInstance: Bool
    /// 是否在 Finder 自定义工具栏菜单中显示
    let showInToolbar: Bool
    /// 是否在右键菜单中显示
    let showInContextMenu: Bool
    /// 「选中文件时打开所在目录」显式开关；nil = 未手动设置（跟随预设终端分类）
    let opensContainingDir: Bool?

    init(id: String, name: String, icon: String, tag: Int, appURL: String? = nil, opensNewInstance: Bool = false,
         showInToolbar: Bool = true, showInContextMenu: Bool = true, opensContainingDir: Bool? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.tag = tag
        self.appURL = appURL
        self.opensNewInstance = opensNewInstance
        self.showInToolbar = showInToolbar
        self.showInContextMenu = showInContextMenu
        self.opensContainingDir = opensContainingDir
    }

    func isVisible(for trigger: MenuTrigger) -> Bool {
        trigger == .toolbar ? showInToolbar : showInContextMenu
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, tag, appURL, opensNewInstance
        case showInToolbar, showInContextMenu, opensContainingDir
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        icon = try values.decode(String.self, forKey: .icon)
        tag = try values.decode(Int.self, forKey: .tag)
        appURL = try values.decodeIfPresent(String.self, forKey: .appURL)
        opensNewInstance = try values.decodeIfPresent(Bool.self, forKey: .opensNewInstance) ?? false
        showInToolbar = try values.decodeIfPresent(Bool.self, forKey: .showInToolbar) ?? true
        showInContextMenu = try values.decodeIfPresent(Bool.self, forKey: .showInContextMenu) ?? true
        opensContainingDir = try values.decodeIfPresent(Bool.self, forKey: .opensContainingDir)
    }

}

/// Menu item for custom actions (copy path, delete, etc.)
struct ActionMenuItem: Codable {
    let id: String
    let name: String
    let icon: String
    let tag: Int

    init(id: String, name: String, icon: String, tag: Int) {
        self.id = id
        self.name = name
        self.icon = icon
        self.tag = tag
    }
}

/// Menu item for creating new files
struct NewFileMenuItem: Codable {
    static let customFileId = "__rclick_custom_new_file"

    let id: String
    let name: String
    let ext: String
    let icon: String

    init(id: String, name: String, ext: String, icon: String) {
        self.id = id
        self.name = name
        self.ext = ext
        self.icon = icon
    }
}

// MARK: - Conversion Extensions

extension RCAction {
    /// 本地化显示名称
    var displayName: String {
        switch id {
        case "copy-path": return AppLocalization.localized("Copy Path")
        case "copy-file-name": return AppLocalization.localized("Copy File Name")
        case "delete-direct": return AppLocalization.localized("Delete Direct")
        default: return name
        }
    }

    /// Convert RCAction to ActionMenuItem for the extension
    func toActionMenuItem() -> ActionMenuItem {
        return ActionMenuItem(
            id: id,
            name: displayName,
            icon: icon,
            tag: idx
        )
    }
}

extension OpenWithApp {
    /// Convert OpenWithApp to AppMenuItem for the extension
    func toAppMenuItem() -> AppMenuItem {
        return AppMenuItem(
            id: id,
            name: name,
            icon: "app",
            tag: 0,
            appURL: url.path,
            opensNewInstance: opensNewInstance,
            showInToolbar: showInToolbar,
            showInContextMenu: showInContextMenu,
            opensContainingDir: opensContainingDir
        )
    }
}
