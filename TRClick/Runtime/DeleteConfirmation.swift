//
//  DeleteConfirmation.swift
//  TRClick
//
//  Permanent-delete confirmation UI, injected into ActionService so tests can
//  assert confirm/cancel without opening a modal.
//

import AppKit
import Foundation

/// Confirms permanent (non-Trash) deletes. Injected so tests can mock the alert.
@MainActor
protocol DeleteConfirmationProviding: AnyObject {
    func confirmPermanentDelete(paths: [String]) async -> Bool
}

@MainActor
final class AlertDeleteConfirmation: DeleteConfirmationProviding {
    private let previewLimit = 5

    func confirmPermanentDelete(paths: [String]) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppLocalization.localized("Delete"))
        alert.addButton(withTitle: AppLocalization.localized("Cancel"))
        alert.buttons[0].hasDestructiveAction = true

        // 预览只需要前五项；文件名直接从路径字符串提取，不探测文件系统。
        let count = paths.count
        let names = paths.prefix(previewLimit).map { ($0 as NSString).lastPathComponent }
        let irreversible = AppLocalization.localized("This cannot be undone and will not move items to Trash.")
        let optionHint = AppLocalization.localized("Tip: hold Option while choosing this action to skip the confirmation.")

        if count == 1 {
            alert.messageText = String(format: AppLocalization.localized("Permanently delete “%@”?"), names[0])
            alert.informativeText = irreversible + "\n\n" + optionHint
        } else {
            alert.messageText = String(format: AppLocalization.localized("Permanently delete %lld items?"), Int64(count))
            var listed = names.joined(separator: "\n")
            let remainder = count - previewLimit
            if remainder > 0 { listed += "\n" + String(format: AppLocalization.localized("...and %lld more"), Int64(remainder)) }
            alert.informativeText = listed + "\n\n" + irreversible + "\n\n" + optionHint
        }
        // 先完成弹窗准备，再让当前动作任务挂起，将激活和显示交给主队列调度。
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)
                }
                continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }
}
