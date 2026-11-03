//
//  ModelDisplayNames.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation

/// Display names from CC Switch's `model_pricing` table ("claude-opus-5-5" → "Claude Opus 5.5"),
/// matched the way CC Switch matches a logged model to its price: `find_model_pricing_row` and
/// `model_pricing_candidates` in `src-tauri/src/services/usage_stats.rs`, commit `c018907`.
public struct ModelDisplayNames: Equatable, Sendable {
    /// Lowercased `model_id` → `display_name`.
    private let names: [String: String]

    public init(_ pairs: [(id: String, name: String)]) {
        var names: [String: String] = [:]
        for pair in pairs where !pair.name.trimmingCharacters(in: .whitespaces).isEmpty {
            names[pair.id.lowercased()] = pair.name
        }
        self.names = names
    }

    public static let empty = ModelDisplayNames([])

    /// The display name for a logged model, or nil when no pricing row matches.
    public func name(for model: String) -> String? {
        let candidates = Self.candidates(model)
        // Exact (case-insensitive) matches win over prefix matches, as in CC Switch.
        for candidate in candidates {
            if let name = names[candidate] { return name }
        }
        for candidate in candidates where Self.allowsPrefixMatch(candidate) {
            // `LIKE '<candidate>-%' ORDER BY LENGTH(model_id) LIMIT 1`; ties fall to the smaller ID.
            let prefix = candidate + "-"
            if let match = names.keys.filter({ $0.hasPrefix(prefix) })
                .min(by: { ($0.count, $0) < ($1.count, $1) })
            {
                return names[match]
            }
        }
        return nil
    }

    // MARK: - CC Switch's candidate rules

    static func candidates(_ model: String) -> [String] {
        let cleaned = clean(model)
        guard !isPlaceholder(cleaned) else { return [] }
        var candidates: [String] = []
        var queue = [cleaned]
        while let candidate = queue.popLast() {
            guard !candidate.isEmpty, !candidates.contains(candidate) else { continue }
            candidates.append(candidate)
            for strip in [
                stripNamespace, stripDesktopPrefix, stripBedrockVersion, stripDateSuffix, stripEffortSuffix
            ] {
                if let stripped = strip(candidate) { queue.append(stripped) }
            }
            if candidate.hasPrefix("claude-"), candidate.contains(".") {
                queue.append(candidate.replacingOccurrences(of: ".", with: "-"))
            }
        }
        return candidates
    }

    /// `clean_model_id_for_pricing`: the last path part, before any ":", lowercased, without "[1m]".
    private static func clean(_ model: String) -> String {
        let last = model.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? model
        let base = last.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? last
        var normalized = base.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "-")
            .lowercased()
        while normalized.hasSuffix("[1m]") { normalized.removeLast(4) }
        return normalized.trimmingCharacters(in: .whitespaces)
    }

    private static func isPlaceholder(_ model: String) -> Bool {
        ["", "unknown", "null", "none"].contains(model.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func stripNamespace(_ model: String) -> String? {
        if let range = model.range(of: "claude-", options: .backwards), range.lowerBound > model.startIndex {
            return String(model[range.lowerBound...])
        }
        for marker in ["openai.", "anthropic.", "google.", "moonshot.", "moonshotai.", "bedrock.", "global."]
        where model.hasPrefix(marker) {
            return String(model.dropFirst(marker.count))
        }
        return nil
    }

    private static let nonAnthropicMarkers = [
        "abab", "ark-code", "arctic", "astron", "codex", "command-r", "deepseek", "doubao", "ernie", "gemini",
        "gemma", "glm", "gpt", "grok", "hermes", "hy3", "hunyuan", "jamba", "kimi", "lfm", "llama", "longcat",
        "mercury", "mimo", "minimax", "mistral", "mixtral", "moonshot", "nemotron", "nova-", "openai", "qianfan",
        "qwen", "seed-", "solar", "stepfun"
    ]

    /// `strip_claude_desktop_non_anthropic_prefix`: "claude-gpt-…" → "gpt-…".
    private static func stripDesktopPrefix(_ model: String) -> String? {
        guard model.hasPrefix("claude-") else { return nil }
        let rest = String(model.dropFirst("claude-".count))
        return nonAnthropicMarkers.contains(where: rest.hasPrefix) ? rest : nil
    }

    /// `strip_bedrock_model_version_suffix`: "…-v1" → "…".
    private static func stripBedrockVersion(_ model: String) -> String? {
        guard let range = model.range(of: "-v", options: .backwards) else { return nil }
        let base = model[..<range.lowerBound]
        let suffix = model[range.upperBound...]
        return !base.isEmpty && !suffix.isEmpty && suffix.allSatisfy(Self.isDigit) ? String(base) : nil
    }

    /// `strip_model_date_suffix`: "-2025-06-15", "-20250615", or a plausible "-YYMMDD".
    private static func stripDateSuffix(_ model: String) -> String? {
        let bytes = Array(model.utf8)
        if bytes.count > 11 {
            let suffix = bytes.suffix(11).map { $0 }
            let digits = { (range: Range<Int>) in suffix[range].allSatisfy { (48...57).contains($0) } }
            if suffix[0] == 45, digits(1..<5), suffix[5] == 45, digits(6..<8), suffix[8] == 45, digits(9..<11) {
                return String(decoding: bytes.dropLast(11), as: UTF8.self)
            }
        }
        guard let dash = model.lastIndex(of: "-") else { return nil }
        let base = model[..<dash]
        let suffix = model[model.index(after: dash)...]
        guard !base.isEmpty, suffix.allSatisfy(Self.isDigit) else { return nil }
        if suffix.count == 8 { return String(base) }
        if suffix.count == 6 {
            let digits = Array(suffix)
            let month = Int(String(digits[2...3])) ?? 0
            let day = Int(String(digits[4...5])) ?? 0
            if (1...12).contains(month), (1...31).contains(day) { return String(base) }
        }
        return nil
    }

    private static func stripEffortSuffix(_ model: String) -> String? {
        for suffix in ["-minimal", "-low", "-medium", "-high", "-xhigh"] where model.hasSuffix(suffix) {
            let stripped = String(model.dropLast(suffix.count))
            if !stripped.isEmpty { return stripped }
        }
        return nil
    }

    private static func isDigit(_ character: Character) -> Bool { character.isASCII && character.isNumber }

    /// `should_try_pricing_prefix_match`: only model families whose IDs extend with "-…".
    private static func allowsPrefixMatch(_ model: String) -> Bool {
        let dashes = model.filter { $0 == "-" }.count
        if model.hasPrefix("claude-") { return dashes >= 3 }
        if ["o1", "o3", "o4", "o5"].contains(where: model.hasPrefix) { return dashes >= 1 }
        let families = ["gpt-", "gemini-", "deepseek-", "qwen-", "glm-", "kimi-", "minimax-"]
        return families.contains(where: model.hasPrefix) && dashes >= 2
    }

    // MARK: - Reading

    /// Reads `model_pricing`; an older CC Switch without the table gives no names.
    static func read(_ connection: ReadOnlyDatabase) -> ModelDisplayNames {
        var pairs: [(id: String, name: String)] = []
        do {
            try connection.query("SELECT model_id, display_name FROM model_pricing", bind: []) { row in
                if let id = row.text(0), let name = row.text(1) { pairs.append((id, name)) }
            }
        } catch {
            return .empty
        }
        return ModelDisplayNames(pairs)
    }
}
