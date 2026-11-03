//
//  SnapshotStore.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation

/// The last observation Tidemark saw for an account. Never holds a credential.
struct StoredAccount: Codable, Equatable {
    var email: String?
    var plan: String?
    var windows: [QuotaWindow]

    var observedAt: Date { windows.map(\.observedAt).max() ?? .distantPast }
}

/// Tidemark's own last-good copy, `usage-snapshots.json` in its Application Support directory.
struct SnapshotStore {
    let url: URL

    func load() -> [String: StoredAccount] {
        guard let data = try? Data(contentsOf: url),
            let accounts = try? Self.decoder.decode([String: StoredAccount].self, from: data)
        else { return [:] }
        return accounts
    }

    func save(_ accounts: [String: StoredAccount]) {
        guard let data = try? Self.encoder.encode(accounts) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
