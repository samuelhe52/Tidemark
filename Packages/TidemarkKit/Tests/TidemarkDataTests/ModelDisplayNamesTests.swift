//
//  ModelDisplayNamesTests.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Testing

@testable import TidemarkData

struct ModelDisplayNamesTests {
    private let names = ModelDisplayNames([
        (id: "claude-opus-5-5", name: "Claude Opus 5.5"),
        (id: "claude-opus-5", name: "Claude Opus 5"),
        (id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
        (id: "gpt-6.1-sol-pro", name: "GPT-6.1 Sol Pro"),
        (id: "blank", name: " ")
    ])

    @Test func matchesLikeCCSwitchPricing() {
        // Exact, ignoring case.
        #expect(names.name(for: "Claude-Opus-5-5") == "Claude Opus 5.5")
        // Cleaned: path prefix, ":" tail and the 1M-context marker go.
        #expect(names.name(for: "openrouter/claude-opus-5-5:beta") == "Claude Opus 5.5")
        #expect(names.name(for: "claude-opus-5-5[1m]") == "Claude Opus 5.5")
        // Stripped: namespaces, Bedrock versions, dates, reasoning effort, dotted Claude versions.
        #expect(names.name(for: "us.anthropic.claude-opus-5-5-20261001-v1") == "Claude Opus 5.5")
        #expect(names.name(for: "gpt-6.1-sol-2026-10-01") == "GPT-6.1 Sol")
        #expect(names.name(for: "gpt-6.1-sol-high") == "GPT-6.1 Sol")
        #expect(names.name(for: "claude-opus-5.5") == "Claude Opus 5.5")
        // An exact match wins over a longer prefix match.
        #expect(names.name(for: "gpt-6.1-sol") == "GPT-6.1 Sol")
    }

    @Test func prefixMatchesOnlyAllowedFamiliesAndShortestID() {
        // "claude-opus-5" has two dashes: too short to prefix-match "claude-opus-5-5".
        #expect(ModelDisplayNames([(id: "claude-opus-5-5", name: "A")]).name(for: "claude-opus-5") == nil)
        // "gpt-6.1" (one dash) is too short; "gpt-6.1-sol" prefix-matches its shortest extension.
        #expect(names.name(for: "gpt-6.1") == nil)
        let shortest = ModelDisplayNames([(id: "gpt-6.1-sol-pro", name: "Pro"), (id: "gpt-6.1-sol-x", name: "X")])
        #expect(shortest.name(for: "gpt-6.1-sol") == "X")
        // Placeholders, blank names and unknown models get no name.
        #expect(names.name(for: "unknown") == nil)
        #expect(names.name(for: "blank") == nil)
        #expect(names.name(for: "mystery-model") == nil)
    }
}
