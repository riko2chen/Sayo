import Foundation

/// Files are installation evidence only. Chrome's live Prompt API is authoritative.
public struct ChromeNanoInstallation: Equatable, Sendable {
    public struct Component: Equatable, Sendable {
        public let version: String
        public let bytes: Int64
    }
    public let chromeInstalled: Bool
    public let components: [Component]
    public let fileInspectionUnavailable: Bool

    public static func inspect(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               applications: URL = URL(fileURLWithPath: "/Applications")) -> Self {
        let manager = FileManager.default
        let chromeInstalled = [applications, home.appendingPathComponent("Applications")].contains {
            manager.fileExists(atPath: $0.appendingPathComponent("Google Chrome.app/Contents/MacOS/Google Chrome").path)
        }
        let root = home.appendingPathComponent("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel")
        let versions: [URL]
        do { versions = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
        catch {
            let missing = (error as NSError).domain == NSCocoaErrorDomain
                && (error as NSError).code == NSFileReadNoSuchFileError
            return Self(chromeInstalled: chromeInstalled, components: [], fileInspectionUnavailable: !missing)
        }
        var unreadable = false
        let components = versions.compactMap { directory -> Component? in
            let data: Data
            do { data = try Data(contentsOf: directory.appendingPathComponent("manifest.json")) }
            catch {
                if (error as NSError).code != NSFileReadNoSuchFileError { unreadable = true }
                return nil
            }
            guard
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = manifest["version"] as? String, !version.isEmpty,
                  manager.fileExists(atPath: directory.appendingPathComponent("on_device_model_execution_config.pb").path),
                  let attributes = try? manager.attributesOfItem(atPath: directory.appendingPathComponent("weights.bin").path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes > 0 else { return nil }
            return Component(version: version, bytes: bytes)
        }.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        return Self(chromeInstalled: chromeInstalled, components: components, fileInspectionUnavailable: unreadable)
    }
}
