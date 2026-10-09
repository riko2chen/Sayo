import AppKit
import SayoCore

/// LobeHub artwork is bundled locally and decoded as native vector images.
enum ProviderIconAssets {
    static func resourceName(for provider: ProviderKind) -> String? {
        switch provider {
        case .deepSeek: return "deepseek-color"
        case .doubao: return "doubao-color"
        case .gemini, .chromeNano: return "gemini-color"
        case .internAI: return "internlm-color"
        case .qwen: return "qwen-color"
        case .moonshot: return "kimi"
        case .zhipu: return "zhipu-color"
        case .siliconFlow: return "siliconcloud-color"
        case .openRouter: return "openrouter-color"
        case .openCode: return "opencode"
        case .openAICompatible: return "openai"
        case .anthropic: return "anthropic"
        case .localModel, .custom, .magpie: return nil
        }
    }

    static func image(for provider: ProviderKind) -> NSImage? {
        guard let name = resourceName(for: provider) else { return nil }
        return images[name]
    }

    private static let images: [String: NSImage] = {
        let names = Set(ProviderKind.allCases.compactMap { resourceName(for: $0) })
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
                  let image = NSImage(contentsOf: url) else { return nil }
            image.isTemplate = false
            return (name, image)
        })
    }()
}
