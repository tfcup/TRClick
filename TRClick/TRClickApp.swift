//
//  TRClickApp.swift
//  TRClick
//
//  Created by 李旭 on 2024/4/4.
//
import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import SwiftData

import FinderSync
import os.log

extension NSNotification.Name {
    static let menuConfigShouldUpdate = NSNotification.Name("TRClick.menuConfigShouldUpdate")
    static let openSettingsRequested = NSNotification.Name("TRClick.openSettingsRequested")
}

@main
struct TRClickApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    @AppStorage(Key.showMenuBarExtra, store: .group) private var showMenuBarExtra = true

    @StateObject private var updateManager = UpdateManager(
        owner: "tfcup",
        repo: "TRClick",
        currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    )

    var body: some Scene {
        // 设置窗口由 SettingsWindowController 以 AppKit 方式持有，不再用
        // SwiftUI 的 Window scene（菜单栏应用里它会随 App 失焦被隐藏）。
        //
        // showMenuBarExtra 为 true 时显示菜单条。label 必须用自定义视图
        // （MenuBarExtraLabel）：openSettingsRequested 的订阅挂在那里，默认的
        // 字符串+图片标签里没有我们的代码可挂。
        MenuBarExtra(
            isInserted: $showMenuBarExtra
        ) {
            MenuBarView(updateManager: updateManager)
        } label: {
            MenuBarExtraLabel(updateManager: updateManager)
        }
        .defaultAppStorage(.group)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    @AppLog(category: "AppDelegate")
    private var logger

    /// 惰性求值：`AppState.shared` 会一路构造到 `ModelContext(sharedModelContainer)`，
    /// 所以必须等 `init` 里 `bootstrap()` 成功之后才碰它。写成默认值属性会在 init 体
    /// 之前求值，正好把顺序反过来。
    lazy var appState: AppState = .shared
    private var pluginActivity = PeerActivity()
    var pluginRunning: Bool { pluginActivity.isActive() }
    var heartBeatCount = 0

    let messager = Messager.shared
    var showMenuBarExtra = UserDefaults.group.bool(forKey: Key.showMenuBarExtra)

    override init() {
        super.init()

        // 先把共享库打开：失败就带着原因退出，而不是等到 AppState 构造时才崩。
        // 这是启动路径上唯一一处主动打开容器的地方，其余访问都指望它先跑过。
        do {
            try SharedDataManager.bootstrap()
        } catch {
            StartupFailure.presentAndExit(error)
        }
    }

    // MARK: - 重连机制状态

    /// 最大重试次数
    private let maxRunningMessageRetryCount: Int = 6

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        logger.info("applicationDidFinishLaunching called")

        // 设置窗口打开策略。注意 TRClick 是 LSUIElement 应用，启动时系统不会
        // 激活它（NSApp.isActive 恒为 false），无法用激活状态区分启动来源，
        // 改用两个显式信号：
        // - 扩展离线提示点击 → OpenConfiguration.environment 带 RC_QUIET_LAUNCH=1
        // - 开机自启 → 系统运行时长 < 3 分钟（实测 SMAppService 登录项与手动
        //   open 的 launchd 标签格式一致，环境变量无法区分，时长是唯一可用信号）
        // 其余（手动 open/双击、崩溃后重启）→ 打开设置窗口
        // App 已运行时再次 open 不会重跑本方法，由 applicationShouldHandleReopen
        // 接住，同样打开设置窗口
        // 时长判定仅在登录项开启时参与：用户没开自启就不存在"开机自启"场景，
        // 开机后手动打开的行为与任何时刻一致
        let processInfo = ProcessInfo.processInfo
        let isHintClickLaunch = processInfo.environment["RC_QUIET_LAUNCH"] == "1"
        let isBootLaunch = LaunchAtLogin.isEnabled && processInfo.systemUptime < 180
        let willOpenSettings = !isHintClickLaunch && !isBootLaunch
        logger.info("launch decision: hintClick=\(isHintClickLaunch, privacy: .public) bootLaunch=\(isBootLaunch, privacy: .public) uptime=\(Int(processInfo.systemUptime), privacy: .public)s openSettings=\(willOpenSettings, privacy: .public)")
        if willOpenSettings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
            }
        }

        // 监听菜单配置更新通知（设置页 toggle 动作时触发）
        NotificationCenter.default.addObserver(
            forName: .menuConfigShouldUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sendMenuConfigurationUpdate()
            }
        }

        // LSUIElement 让后台启动默认不显示 Dock 图标，避免启动早期短暂出现图标。
        // SettingsWindowController 在打开设置窗口时切换为 regular，关闭时恢复 accessory；
        // 最小化和切换应用不改变 Dock 图标状态。

        // 迁移旧的"开机登录"设置（修复前该开关只写入 UserDefaults，未真正注册登录项）
        migrateLegacyLaunchAtLoginSetting()

        // 执行数据迁移
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // 初始化默认数据
            let context = ModelContext(SharedDataManager.sharedModelContainer)
            do {
                try await SharedDataManager.initializeDefaultData(context: context)
            } catch {
                StartupFailure.presentAndExit(error)
            }

            // 补齐全默认动作后刷新内存快照，让新增动作在本次启动就进入菜单
            appState.refresh()
            sendMenuConfigurationUpdate()

            // Preload icons for all apps to improve performance
            Task { @MainActor in
                IconCache.shared.preloadIcons(for: appState.apps.map { $0.url })
            }

            // Register message handlers using type-safe API
            logger.info("Registering message handlers")
            messager.onExtensionMessage(.click) { [weak self] data in
                guard let self = self else { return }
                if let event: ClickEventPayload = messager.decodeSignedData(data) {
                    // 确认收到，供扩展判断主程序可通信性（操作成败另议）
                    messager.sendActionAck()
                    Task { @MainActor in
                        await self.handleClickEvent(event)
                    }
                } else {
                    logger.warning("Invalid click event data")
                }
            }

            messager.onExtensionMessage(.heartbeat) { [weak self] _ in
                guard let self = self else { return }
                logger.debug("Received heartbeat from extension")
                // Acknowledge every heartbeat without re-sending the menu configuration.
                // The extension needs a reply to keep its own liveness cache online.
                let reconnected = pluginActivity.receive()
                messager.sendRunningNotification()
                if reconnected {
                    sendMenuConfigurationUpdate()
                }
            }

            // 处理 Extension 请求菜单配置
            messager.onExtensionMessage(.requestConfig) { [weak self] _ in
                guard let self = self else { return }
                logger.info("Received menu config request from extension")
                self.sendMenuConfigurationUpdate()
            }

            // 启动 running 消息重试机制
            startRunningMessageRetry()

            sendObserveDirMessage()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// 用户在 App 已运行时再次打开（Finder 双击 / `open` 命令）：launch 流程不会
    /// 重跑，applicationDidFinishLaunching 不再执行——这正是"App 明明开着，
    /// 再点一次却什么都没发生"的原因。这里把它转成与首次手动启动一致的行为：
    /// 调出设置窗口。订阅方是 MenuBarExtra 的标签视图（MenuBarExtraLabel），
    /// 它从启动起就存在。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 提示点击若落在「App 已在运行 / 正在退出收尾」的窗口里，系统会忽略
        // RC_QUIET_LAUNCH 环境变量、只派发 reopen；自用版不再写跨进程标记文件，
        // 这种情况下会正常弹出设置页。
        logger.info("reopen: hasVisibleWindows=\(flag, privacy: .public)")
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        messager.sendQuitNotification()
        logger.info("applicationWillTerminate")
    }

    /// 迁移旧的"开机登录"设置。
    /// 修复前该开关仅写入 UserDefaults("launchAtLogin")，并未真正调用 SMAppService 注册登录项。
    /// 若检测到旧值为开启，则补齐注册，并清除旧标记避免重复迁移。
    private func migrateLegacyLaunchAtLoginSetting() {
        let legacyKey = "launchAtLogin"
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: legacyKey) else { return }

        defaults.removeObject(forKey: legacyKey)

        if !LaunchAtLogin.isEnabled {
            LaunchAtLogin.isEnabled = true
        }
    }

    // MARK: - Message Handlers

    func sendObserveDirMessage() {
        let directories: [String] = []
        messager.sendRunningNotification(directories: directories)
        if !pluginRunning {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                sendObserveDirMessage()
            }
        }
    }

    func sendMenuConfigurationUpdate() {
        let config = RCRuntime.shared.menuService.buildConfig(from: appState)
        messager.sendMenuConfig(config)
        logger.debug("Sent menu configuration to extension: \(config.actions.count) actions, \(config.apps.count) apps")
    }

    func handleClickEvent(_ event: ClickEventPayload) async {
        // 是否跳过删除确认以扩展在菜单构建时定下的标记为准。主程序不再读取
        // 实时按键状态，避免与扩展显示的菜单标题不一致。旧版扩展未携带该字段
        // 时按 false 处理，即弹出确认框——这是安全方向。
        let optionKeyPressed = event.optionKeyPressed ?? false
        logger.info("Click option: payload=\(String(describing: event.optionKeyPressed)) resolved=\(optionKeyPressed)")
        logger.debug("Handling click event: \(event.itemId) type=\(event.itemType.rawValue) trigger=\(event.trigger.rawValue) target=\(event.target)")

        let actionService = RCRuntime.shared.actionService

        switch event.itemType {
        case .app:
            await actionService.openApp(rid: event.itemId, target: event.target)
        case .action:
            await actionService.actionHandler(
                rid: event.itemId,
                target: event.target,
                trigger: event.trigger.rawValue,
                optionKeyPressed: optionKeyPressed
            )
        case .newFile:
            await actionService.createFile(rid: event.itemId, target: event.target)
        }
    }

    // MARK: - 重连机制

    /// 启动 running 消息重试机制（每 5 秒发送一次，持续 30 秒）
    private func startRunningMessageRetry() {
        Task { @MainActor in
            for retryCount in 0..<self.maxRunningMessageRetryCount {
                try? await Task.sleep(for: .seconds(5))
                guard !self.pluginRunning else { break }
                self.messager.sendRunningNotification()
                self.logger.debug("Sending running message retry \(retryCount + 1)/\(self.maxRunningMessageRetryCount)")
            }
            logger.debug("Running message retry completed")
        }
    }

}
