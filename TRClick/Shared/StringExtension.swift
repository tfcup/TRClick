//
//  StringExtension.swift
//  TRClick
//

import Foundation

enum Key {
    static let showMenuBarExtra = "showMenuBarExtra"
    /// 新建文件后自动重命名缺少辅助功能权限时，是否已经提示过一次
    static let didShowRenamePermissionHint = "didShowRenamePermissionHint"
}

extension UserDefaults {
    /// 自用版不再使用 App Group。保留这个名字，让所有 `store: .group` 的调用点不必改动。
    static let group: UserDefaults = .standard
}
