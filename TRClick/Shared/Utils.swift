import Foundation

public class Utils {
    /// 统一路径格式后比较目录本身，避免尾部斜杠导致保护失效。
    public static func isProtectedFolder(_ path: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return Constants.protectedDirs.contains { protectedPath in
            normalizedPath == URL(fileURLWithPath: protectedPath).standardizedFileURL.path
        }
    }
    // MARK: 
    public static func getRealHomeDir() -> String {
        let fullPath = NSHomeDirectory()
        let components = fullPath.components(separatedBy: "/")
        let limitedComponents = Array(components.prefix(3))  // 取前3个是因为第一个是空字符串（路径以/开头）
        return limitedComponents.joined(separator: "/")
    }
}
