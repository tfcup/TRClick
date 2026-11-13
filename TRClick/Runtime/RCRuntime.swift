//
//  RCRuntime.swift
//  TRClick
//
//  进程内 Runtime 依赖容器：持有 AppState 与各 Service，AppDelegate 按需取。
//  注意：这是 Main App 进程内的架构层，不是独立进程 / Helper。
//

import Foundation

@MainActor
final class RCRuntime {
    static let shared = RCRuntime()

    /// 运行时状态（配置内存快照 + 菜单显示设置）
    let state: AppState
    /// 菜单构建
    let menuService: MenuService
    /// 权限（直通）
    let permissionService: PermissionService
    /// 动作执行（文件操作）
    let actionService: ActionService

    private init() {
        self.state = AppState.shared
        self.permissionService = PermissionService()
        self.menuService = MenuService()
        self.actionService = ActionService(state: state, permission: permissionService, confirmation: AlertDeleteConfirmation())
    }
}
