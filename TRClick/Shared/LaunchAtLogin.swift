//
//  LaunchAtLogin.swift
//  TRClick
//  from https://github.com/sindresorhus/LaunchAtLogin-Modern

import Foundation

import SwiftUI
import ServiceManagement
import OSLog
import Combine

public enum LaunchAtLogin {
    private static let logger = Logger(subsystem:  Bundle.main.bundleIdentifier ?? "LaunchAtLogin", category: "main")
    fileprivate static let observable = Observable()

    /**
    Toggle “launch at login” for your app or check whether it's enabled.
    */
    public static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            observable.objectWillChange.send()

            do {
                if newValue {
                    if SMAppService.mainApp.status == .enabled {
                        try? SMAppService.mainApp.unregister()
                    }

                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                logger.error("Failed to \(newValue ? "enable" : "disable") launch at login: \(error.localizedDescription)")
            }
        }
    }

}

extension LaunchAtLogin {
    final class Observable: ObservableObject {
        var isEnabled: Bool {
            get { LaunchAtLogin.isEnabled }
            set {
                LaunchAtLogin.isEnabled = newValue
            }
        }
    }
}

extension LaunchAtLogin {
    /// 使用自定义标签控制开机启动，并显示需要系统批准或安装位置不正确的提示。
    public struct Toggle<Label: View>: View {
        @ObservedObject private var launchAtLogin = LaunchAtLogin.observable
        private let label: Label

        /**
        Creates a toggle that displays a custom label.

        - Parameters:
            - label: A view that describes the purpose of the toggle.
        */
        public init(@ViewBuilder label: () -> Label) {
            self.label = label()
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                SwiftUI.Toggle(isOn: $launchAtLogin.isEnabled) { label }
                if let warningKey = warningMessageKey {
                    SwiftUI.Label {
                        Text(AppLocalization.localized(warningKey))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundColor(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        /// 当登录项实际未生效时给出提示：
        /// - .requiresApproval：macOS 13+ 首次启用需用户在系统设置批准
        /// - 其他非 enabled：多半是 app 不在 /Applications（Debug 从 Xcode 跑就是这种）
        private var warningMessageKey: String? {
            switch SMAppService.mainApp.status {
            case .enabled:
                return nil
            case .requiresApproval:
                return "Launch at login is pending approval in System Settings"
            case .notRegistered, .notFound:
                return "Launch at login requires TRClick to be installed in /Applications"
            @unknown default:
                return nil
            }
        }
    }
}

