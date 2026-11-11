//
//  PermissionService.swift
//  TRClick
//
//  权限服务层：自用版主程序不启用 App Sandbox，文件访问直通。
//

import Foundation

/// 权限服务协议（供 ActionService 注入 mock，便于单测）
@MainActor
protocol PermissionProviding: AnyObject {
    /// 主程序不沙盒，恒为 true
    func hasAccess(to url: URL) -> Bool
    /// 不再弹 NSOpenPanel，直接返回原路径
    func promptForPermission(for url: URL) async -> URL?
}

/// 直通实现：不再依赖 security-scoped bookmark。
@MainActor
final class PermissionService: PermissionProviding {
    func hasAccess(to url: URL) -> Bool {
        true
    }

    func promptForPermission(for url: URL) async -> URL? {
        url
    }
}
