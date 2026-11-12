//
//  DataVersion.swift
//  TRClick
//
//  Created by Claude on 2026/01/16.
//

import SwiftData
import Foundation

/// 持久化数据版本与默认配置初始化标记。
@Model
final class DataVersion {
    @Attribute(.unique) var key: String
    var version: Int
    var updatedAt: Date

    init(key: String, version: Int) {
        self.key = key
        self.version = version
        self.updatedAt = Date()
    }
}
