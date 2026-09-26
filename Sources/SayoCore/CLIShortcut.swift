import Foundation

/// The portable terminal keys accepted by the CLI editor integrations.
public enum CLIShortcut {
    public static let defaultKey = "ctrl+g"
    public static let codexOptions = [defaultKey, "f6", "f7", "f8", "f9", "f10", "f11", "f12"]
    private static let names: [UInt32: String] = [
        0:"a", 1:"s", 2:"d", 3:"f", 4:"h", 5:"g", 6:"z", 7:"x", 8:"c", 9:"v",
        11:"b", 12:"q", 13:"w", 14:"e", 15:"r", 16:"y", 17:"t", 31:"o", 32:"u",
        34:"i", 35:"p", 37:"l", 38:"j", 40:"k", 45:"n", 46:"m",
        122:"f1", 120:"f2", 99:"f3", 118:"f4", 96:"f5", 97:"f6", 98:"f7", 100:"f8",
        101:"f9", 109:"f10", 103:"f11", 111:"f12"
    ]
    public static func isValid(_ key: String) -> Bool {
        key.range(of: "^(ctrl\\+[a-z]|alt\\+[a-z]|f([1-9]|1[0-2]))$", options: .regularExpression) != nil
        && !["ctrl+c", "ctrl+d", "ctrl+z", "ctrl+s", "ctrl+q", "ctrl+h", "ctrl+i", "ctrl+j", "ctrl+m"].contains(key)
    }
    public static func key(for shortcut: Shortcut) -> String? {
        guard !shortcut.command, !shortcut.shift, let name = names[shortcut.keyCode] else { return nil }
        let key = (shortcut.control ? "ctrl+" : "") + (shortcut.option ? "alt+" : "") + name
        return isValid(key) ? key : nil
    }
    public static func shortcut(for key: String) -> Shortcut? {
        guard isValid(key), let code = names.first(where: { $0.value == key.components(separatedBy: "+").last })?.key else { return nil }
        return Shortcut(keyCode: code, command: false, option: key.hasPrefix("alt+"), control: key.hasPrefix("ctrl+"), shift: false)
    }
    public static func label(_ key: String) -> String {
        key.replacingOccurrences(of: "ctrl+", with: "⌃").replacingOccurrences(of: "alt+", with: "⌥").uppercased()
    }
}
