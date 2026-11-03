//
//  AccountKey.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation

/// The stable account IDs Tidemark persists: snapshot keys, hidden accounts, order and summary choices.
///
/// Changing a format orphans every saved reading and preference for that account.
enum AccountKey {
    /// `claude:<accountUuid>`, or `claude:local` when the signed-in account is unknown.
    static func claude(_ accountUUID: String?) -> String {
        accountUUID.map { "claude:\($0)" } ?? "claude:local"
    }

    /// `codex:<workspace>`, or `codex:local` when the workspace is unknown. Workspaces alone are
    /// not unique users; managed accounts use `managedCodex`.
    static func codex(_ workspace: String?) -> String {
        workspace.map { "codex:\($0)" } ?? "codex:local"
    }

    /// `codex:managed:<localId>`, one per CC Switch managed Codex account.
    static func managedCodex(_ localID: String) -> String {
        "codex:managed:\(localID)"
    }
}
