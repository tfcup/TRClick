//
//  Extension+.swift
//  TRClick
//

import Foundation
import SwiftUI

extension View {
    func onForeground(_ f: @escaping () -> Void) -> some View {
        self.onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            perform: { _ in f() }
        )
    }
}
