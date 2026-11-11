//
//  MenuService.swift
//  TRClick
//
//  菜单配置构建服务：从 AppState 生成发往 Finder Extension 的 MenuConfigPayload。
//  版本号在这里维护，用于防重复和防乱序。
//

import Foundation

@MainActor
final class MenuService {
    /// 菜单版本号（防重复 / 防乱序）
    private var menuVersion = 0

    /// 从 AppState 实时构建菜单配置
    func buildConfig(from state: AppState) -> MenuConfigPayload {
        menuVersion += 1
        return MenuConfigPayload(
            version: menuVersion,
            actions: state.actions.filter(\.enabled).map { $0.toActionMenuItem() },
            apps: state.apps.map { $0.toAppMenuItem() },
            newFiles: state.newFiles.filter(\.enabled).map {
                NewFileMenuItem(id: $0.id, name: $0.displayName, ext: $0.ext, icon: $0.icon)
            },
            actionsCollapsed: state.foldActionsMenu,
            appsCollapsed: state.foldAppsMenu,
            newFilesCollapsed: state.foldNewFileMenu,
            iconStyle: state.appIconStyle
        )
    }
}
