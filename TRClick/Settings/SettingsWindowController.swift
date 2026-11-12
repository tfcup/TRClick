//
//  SettingsWindowController.swift
//  TRClick
//
//  设置窗口的 AppKit 宿主。
//

import AppKit
import SwiftData
import SwiftUI

/// 自己持有设置窗口，而不是用 SwiftUI 的 `Window` scene。
///
/// 菜单栏（LSUIElement）应用里 scene 的生命周期会在切换到其他 App 时把窗口
/// 隐藏/回收；这里显式关闭 `hidesOnDeactivate`，并让窗口在关闭后仍被复用，
/// 保证只有点红色关闭按钮才会关掉它。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show(updateManager: UpdateManager) {
        if window == nil {
            window = makeWindow(updateManager: updateManager)
        }
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(updateManager: UpdateManager) -> NSWindow {
        let root = SettingsRootView()
            .environmentObject(AppState.shared)
            .environmentObject(updateManager)
            .modelContainer(SharedDataManager.sharedModelContainer)
            .defaultAppStorage(.group)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = AppLocalization.localized("Settings")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.contentMinSize = NSSize(width: 700, height: 480)
        window.setContentSize(NSSize(width: 700, height: 480))
        window.center()
        return window
    }
}

/// 设置窗口的 SwiftUI 根视图（原先挂在 `SettingsWindow` scene 上的配置搬到这里）。
struct SettingsRootView: View {
    @EnvironmentObject private var updateManager: UpdateManager

    var body: some View {
        SettingsView()
            .frame(minWidth: 700, minHeight: 480)
            .sheet(isPresented: $updateManager.showUpdateSheet) {
                UpdateView(updateManager: updateManager)
            }
    }
}
