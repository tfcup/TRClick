//
//  Constants.swift
//  TRClick
//
//  Created by 李旭 on 2024/9/25.
//

import Foundation


public enum Constants {
    static let HomedirPath = Utils.getRealHomeDir()
    static let protectedDirs = [
        HomedirPath + "/Desktop/",
        HomedirPath + "/Desktop/danger/",
        HomedirPath + "/Applications/",
        "/Applications/",
        "/System/",
        "/Library/",
        "/Users/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/var/"
    ]

}
