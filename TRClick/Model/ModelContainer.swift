//
//  ModelContainer.swift
//  TRClick
//
//  Created by 李旭 on 2025/10/3.
//

import Foundation
import SwiftData
import OSLog

/// 共享库打不开的原因。
enum SharedStoreError: LocalizedError {
    /// 目录拿到了，但库文件打不开。
    case storeUnreadable(url: URL, underlying: Error)

    /// 诊断用，不是给用户看的文案 —— 用户看到的那份由 `StartupFailure.describe()`
    /// 组装并走本地化。这里保持英文，避免一条没进 catalog 的中文串从某处
    /// `localizedDescription` 漏到界面上。
    var errorDescription: String? {
        switch self {
        case .storeUnreadable(let url, let underlying):
            return "Cannot open the store at \(url.path): \(underlying)"
        }
    }

}

// 共享 ModelContainer 配置工具类
@MainActor
class SharedDataManager {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TRClick",
        category: "ModelContainer"
    )

    /// `bootstrap()` 打开的那个容器。
    private static var openedContainer: ModelContainer?

    /// 已打开的共享容器。
    ///
    /// 正常路径由启动代码先跑 `bootstrap()`。若仍有更早的访问者（SwiftUI 求值顺序不是
    /// 我们能保证的），这里补一次并走同一个失败出口 —— 总之不再有 trap。
    static var sharedModelContainer: ModelContainer {
        if let openedContainer { return openedContainer }

        do {
            let container = try makeSharedModelContainer()
            openedContainer = container
            return container
        } catch {
            StartupFailure.presentAndExit(error)
        }
    }

    /// 打开共享容器，失败则抛出。
    ///
    /// 启动路径应当在任何东西碰 `sharedModelContainer` 之前调用它。原先是静态 lazy
    /// 初始化 + `fatalError`，于是"读不到库"表现为毫无提示的 SIGTRAP —— 崩溃报告里
    /// 只有 `_assertionFailure`，真正的原因（哪个文件、为什么打不开）随进程一起没了。
    /// 改成显式抛出后，调用方能把原因说清楚再退。
    static func bootstrap() throws {
        guard openedContainer == nil else { return }
        openedContainer = try makeSharedModelContainer()
    }

    /// 共享库位置：`~/Library/Application Support/TRClick/TRClickDatabase.sqlite`。
    ///
    /// 自用版主程序不启用 App Sandbox，也不再依赖 App Group；数据只由主程序读写，
    /// Finder 扩展通过 IPC 拿菜单配置，不碰这里。
    private static func storeFileURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = baseURL.appendingPathComponent("TRClick", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("TRClickDatabase.sqlite")
    }

    /// 定位容器目录并打开 ModelContainer。不做任何 trap，失败一律抛给调用方。
    static func makeSharedModelContainer() throws -> ModelContainer {
        let storeURL = try storeFileURL()

        // 创建 ModelConfiguration 使用共享路径
        let configuration = ModelConfiguration(
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )

        // 创建 ModelContainer，注册所有模型
        do {
            return try ModelContainer(
                for: AppEntity.self,
                     ActionEntity.self,
                     NewFileTypeEntity.self,
                     DataVersion.self,
                configurations: configuration
            )
        } catch {
            logger.error("打开共享 ModelContainer 失败: \(error)")
            throw SharedStoreError.storeUnreadable(url: storeURL, underlying: error)
        }
    }

    /// 首次初始化默认配置；已有安装保留空列表，动作仍按 id 补齐。
    static func initializeDefaultData(context: ModelContext) async throws {
        // 动作表按 id 补齐缺失的默认动作：既覆盖首次安装，也覆盖升级后新增的内置动作。
        // 已有动作保持相对顺序，只在缺失项的位置插入并重新编号。
        let actionDescriptor = FetchDescriptor<ActionEntity>(sortBy: [SortDescriptor(\.sortOrder)])
        let existingActions = try context.fetch(actionDescriptor)
        let appCount = try context.fetchCount(FetchDescriptor<AppEntity>())
        let fileTypeCount = try context.fetchCount(FetchDescriptor<NewFileTypeEntity>())
        let initializationKey = "defaultConfigurationInitialized"
        let versions = try context.fetch(FetchDescriptor<DataVersion>())
        let initialized = versions.contains { $0.key == initializationKey }
        // 旧库没有标记时，只要已有任意配置，就不再把空列表误判为首次安装。
        let shouldSeedLists = !initialized && existingActions.isEmpty && appCount == 0 && fileTypeCount == 0
        let defaultActions = ActionEntity.createDefaultActions()
        let existingIDs = Set(existingActions.map(\.id))
        let missingActions = defaultActions.filter { !existingIDs.contains($0.id) }

        if !missingActions.isEmpty {
            var ordered = existingActions
            for action in missingActions {
                ordered.insert(action, at: min(action.sortOrder, ordered.count))
            }
            for (index, action) in ordered.enumerated() {
                action.sortOrder = index
            }
            for action in missingActions {
                context.insert(action)
            }
            Self.logger.info("已补齐缺失的默认动作: \(missingActions.map(\.id).joined(separator: ", "))")
        }

        // 内置动作的图标由代码维护（设置页没有修改图标的入口），升级后同步一次，
        // 避免旧的默认图标一直留在库里。
        let defaultIcons = Dictionary(uniqueKeysWithValues: defaultActions.map { ($0.id, $0.icon) })
        for action in existingActions {
            guard let icon = defaultIcons[action.id], action.icon != icon else { continue }
            action.icon = icon
        }

        if shouldSeedLists {
            // 插入默认文件类型
            for fileType in NewFileTypeEntity.createDefaultFileTypes() {
                context.insert(fileType)
            }
            Self.logger.info("已初始化默认文件类型")
        }

        if shouldSeedLists {
            for (index, app) in OpenWithApp.defaultApps.enumerated() {
                context.insert(AppEntity(from: app, sortOrder: index))
            }
            Self.logger.info("已初始化默认应用")
        }

        if !initialized {
            context.insert(DataVersion(key: initializationKey, version: 1))
        }
        try context.save()
    }
}
