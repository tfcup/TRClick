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
/// 切换应用不会关闭窗口。Dock 图标随窗口打开/关闭切换，最小化时仍保留。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func show(updateManager: UpdateManager) {
        if window == nil {
            window = makeWindow(updateManager: updateManager)
        }
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // 仅在真正关闭设置窗口后恢复菜单栏模式，失焦和最小化都不隐藏 Dock 图标。
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow(updateManager: UpdateManager) -> NSWindow {
        let root = SettingsRootView()
            .environmentObject(AppState.shared)
            .environmentObject(updateManager)
            .modelContainer(SharedDataManager.sharedModelContainer)
            .defaultAppStorage(.group)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.delegate = self
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
            .sheet(isPresented: $updateManager.showUpdateSheet, onDismiss: {
                updateManager.finishPendingRestart()
            }) {
                UpdateView(updateManager: updateManager)
            }
    }
}
