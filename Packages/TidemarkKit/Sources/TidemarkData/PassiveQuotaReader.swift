//
//  PassiveQuotaReader.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation

/// All external URLs are opened read-only. No credentials or agent configuration are changed.
public actor PassiveQuotaReader {
    private let claudeCache: URL
    private let statusline: URL
    private let sessions: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, codexHome: URL? = nil) {
        claudeCache = home.appending(path: ".claude.json")
        statusline = home.appending(path: "Library/Application Support/Tidemark/claude-rate-limits.json")
        sessions = (codexHome ?? home.appending(path: ".codex")).appending(path: "sessions")
    }

    public func read() -> [ServiceObservation] {
        [readClaude(), readCodex()]
    }

    private func readClaude() -> ServiceObservation {
        var candidates: [[QuotaWindow]] = []
        var hadFile = false
        var unreadable = false
        for (url, parse) in [
            (claudeCache, PassiveQuotaParser.claudeCache),
            (statusline, PassiveQuotaParser.claudeStatusline)
        ] where FileManager.default.fileExists(atPath: url.path) {
            hadFile = true
            do {
                let data = try boundedFile(url, maximumBytes: 4 * 1024 * 1024)
                let windows = parse(data)
                if !windows.isEmpty { candidates.append(windows) }
            } catch { unreadable = true }
        }
        // Do not combine windows from two captures that might belong to different accounts.
        if let latest = candidates.max(by: { $0[0].observedAt < $1[0].observedAt }) {
            return ServiceObservation(service: .claude, windows: latest)
        }
        return ServiceObservation(
            service: .claude, issue: unreadable ? .unreadable : (hadFile ? .unrecognized : .missing))
    }

    private func readCodex() -> ServiceObservation {
        let manager = FileManager.default
        guard manager.fileExists(atPath: sessions.path) else {
            return ServiceObservation(service: .codex, issue: .missing)
        }
        guard
            let enumerator = manager.enumerator(
                at: sessions, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return ServiceObservation(service: .codex, issue: .unreadable) }
        var newest: (URL, Date)?
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true, let date = values.contentModificationDate
            else { continue }
            if newest == nil || date > newest!.1 { newest = (url, date) }
        }
        guard let url = newest?.0 else { return ServiceObservation(service: .codex, issue: .missing) }
        do {
            // One bounded tail, 400 lines at most. Never scan conversation bodies from the start.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let offset = size > 512 * 1024 ? size - 512 * 1024 : 0
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: 512 * 1024) ?? Data()
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            if offset > 0, !lines.isEmpty { lines.removeFirst() }
            for line in lines.suffix(400).reversed() where line.range(of: Data("\"rate_limits\"".utf8)) != nil {
                let windows = PassiveQuotaParser.codexEvent(Data(line))
                if !windows.isEmpty { return ServiceObservation(service: .codex, windows: windows) }
            }
            return ServiceObservation(service: .codex, issue: .unrecognized)
        } catch {
            return ServiceObservation(service: .codex, issue: .unreadable)
        }
    }

    private func boundedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
}
