import SwiftUI

/// Initials and colors for agents in sessions, the Activity Log and Live Activities.
enum Caller {
    /// Specific agent names are matched before more general names.
    private static let known: [(match: [String], tint: UInt32, mark: UInt32)] = [
        (["claude"], 0xD97757, 0xFFFFFF),
        (["anthropic"], 0x191919, 0xF0EEE6),
        (["chatgpt"], 0xFFFFFF, 0x000000),
        (["cursor"], 0x111111, 0xFFFFFF),
        (["windsurf", "codeium"], 0x0B100F, 0xFFFFFF),
        (["cline", "roo code", "roo-code", "roocode"], 0x111111, 0xFFFFFF),
        (["codex", "openai"], 0x000000, 0xFFFFFF),
        (["github", "copilot", "visual studio code", "vscode", "vs code"], 0x24292F, 0xFFFFFF),
        (["microsoft"], 0x0078D4, 0xFFFFFF),
        (["gemini", "google"], 0x4285F4, 0xFFFFFF),
        (["deepseek"], 0x4D6BFE, 0xFFFFFF),
        (["openrouter"], 0x6566F1, 0xFFFFFF),
        (["meta"], 0x0866FF, 0xFFFFFF),
        (["perplexity"], 0x1FB8CD, 0xFFFFFF),
        (["mistral", "le chat", "le-chat", "lechat"], 0xFA520F, 0xFFFFFF),
        (["grok", "xai"], 0x111111, 0xFFFFFF),
        (["raycast"], 0xFF6363, 0xFFFFFF),
        (["goose"], 0x111111, 0xFFFFFF),
        (["manus"], 0x111111, 0xFFFFFF),
        (["kimi", "moonshot"], 0x111111, 0xFFFFFF),
        (["qwen", "tongyi", "alibaba"], 0x615CED, 0xFFFFFF),
        (["lm studio", "lmstudio"], 0x4338CA, 0xFFFFFF),
        (["ollama"], 0x111111, 0xFFFFFF),
        (["hugging", "hf-mcp"], 0xFFB000, 0xFFFFFF),
        (["n8n"], 0xEA4B71, 0xFFFFFF),
        (["zapier"], 0xFF4F00, 0xFFFFFF),
        (["openclaw"], 0xE5484D, 0xFFFFFF),
        (["poke"], 0x111111, 0xFFFFFF),
        (["zed"], 0x084CCF, 0xFFFFFF),
    ]

    private static func entry(_ name: String) -> (match: [String], tint: UInt32, mark: UInt32)? {
        let n = name.lowercased()
        return known.first { $0.match.contains { n.contains($0) } }
    }

    /// The provider's colour, a calm grey otherwise.
    static func tint(_ name: String) -> Color { Color(hex: entry(name)?.tint ?? 0x8E8E93) }

    static func isLight(_ name: String) -> Bool { entry(name)?.tint == 0xFFFFFF }

    /// A tile that disappears on a dark ground (OpenAI's black, Cursor's near-black): under a fifth of white.
    static func isDark(_ name: String) -> Bool {
        let hex = entry(name)?.tint ?? 0x8E8E93
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 < 0.2
    }

    /// The initials’ color on the tile.
    static func mark(_ name: String) -> Color { Color(hex: entry(name)?.mark ?? 0xFFFFFF) }

    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ")
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(name.prefix(1)).uppercased()
    }
}

/// The caller's round badge.
struct CallerBadge: View {
    var name: String
    var size: CGFloat
    /// On a dark ground, a dark tile turns light for contrast.
    var lifted = false
    var body: some View {
        let invert = lifted && Caller.isDark(name)
        Text(verbatim: Caller.initials(name))
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
        .foregroundStyle(invert ? Color(hex: 0x111111) : Caller.mark(name))
        .frame(width: size, height: size)
        .background(invert ? Color(hex: 0xF2F2F7) : Caller.tint(name), in: .circle)
        // A white tile (ChatGPT) keeps its edge on a white page.
        .overlay(Circle().strokeBorder(Color(.separator), lineWidth: Caller.isLight(name) ? 0.5 : 0))
        .accessibilityLabel(Text(verbatim: name))
    }
}
