import Foundation

public enum AppFeature: Hashable, Sendable {
    case focusedInput
    case terminalIntegration
}

public extension AppFeature {
    static let shipped: Set<AppFeature> = [.focusedInput, .terminalIntegration]
}
