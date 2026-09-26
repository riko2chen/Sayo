import Foundation
import Security
import SayoCore

public enum SettingsFileError: LocalizedError {
    case credentialsInURL
    case invalidBaseURL

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Base URL 格式无效。 / Invalid Base URL."
        case .credentialsInURL:
            return "Base URL 不能包含凭据、查询参数或片段。请使用 API Key 字段，密钥只会保存在 macOS 钥匙串中。 / Base URL must not contain credentials, query parameters, or fragments. Use the API key field to store secrets in macOS Keychain."
        }
    }
}

@MainActor
public final class DiskSettingsRepository: SettingsRepository {
    public let url: URL
    private let legacyURL: URL

    public init(url: URL? = nil) {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.url = url ?? applicationSupport
            .appendingPathComponent("Sayo", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
        self.legacyURL = self.url.deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    public func load() throws -> AppSettings {
        if FileManager.default.fileExists(atPath: url.path) {
            return try decode(url)
        }
        let settings = FileManager.default.fileExists(atPath: legacyURL.path)
            ? try decode(legacyURL) : AppSettings()
        try save(settings)
        return settings
    }

    /// Check before changing Keychain, login items, or shortcuts as part of a save.
    public func validateForSave(_ settings: AppSettings) throws {
        try settings.validateTranslationShortcuts()
        // A damaged/newer file must never be replaced with startup fallback defaults.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try decode(url)
        } else if FileManager.default.fileExists(atPath: legacyURL.path) {
            _ = try decode(legacyURL)
        }
        for configuration in [settings.llm] + Array(settings.providerConfigurations.values) {
            let endpoint = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: endpoint) else {
                throw SettingsFileError.invalidBaseURL
            }
            if components.user != nil || components.password != nil || components.query != nil || components.fragment != nil {
                throw SettingsFileError.credentialsInURL
            }
        }
    }

    public func save(_ settings: AppSettings) throws {
        try validateForSave(settings)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func decode(_ source: URL) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: source))
    }
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    public init(service: String = Bundle.main.bundleIdentifier ?? "Sayo") {
        self.service = service
    }

    public func readKey(for profileID: String) throws -> String? {
        var query = baseQuery(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw SayoPlatformError.keychain(status)
        }
        return value
    }

    public func saveKey(_ value: String, for profileID: String) throws {
        if value.isEmpty {
            try removeKey(for: profileID)
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(for: profileID)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SayoPlatformError.keychain(updateStatus)
        }

        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SayoPlatformError.keychain(addStatus)
        }
    }

    private func removeKey(for profileID: String) throws {
        let status = SecItemDelete(baseQuery(for: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SayoPlatformError.keychain(status)
        }
    }

    private func baseQuery(for profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID
        ]
    }
}
