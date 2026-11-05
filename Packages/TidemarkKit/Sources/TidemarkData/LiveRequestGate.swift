//
//  LiveRequestGate.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation

/// Decides when a live request may go out, per account.
///
/// Automatic refreshes wait at least five minutes; a user's refresh waits 20 seconds. After a
/// failure the account waits for `Retry-After`, or for an exponential backoff with jitter.
/// A user's refresh never skips a backoff.
struct LiveRequestGate {
    static let automaticInterval: TimeInterval = 300
    static let userInterval: TimeInterval = 20
    static let firstBackoff: TimeInterval = 60
    static let longestBackoff: TimeInterval = 1800

    private struct Entry {
        var lastAttempt: Date
        var notBefore: Date
        var failures: Int
    }

    private var entries: [String: Entry] = [:]

    func allows(_ key: String, now: Date, userInitiated: Bool) -> Bool {
        guard let entry = entries[key] else { return true }
        guard now >= entry.notBefore else { return false }
        if entry.failures > 0 { return true }
        let interval = userInitiated ? Self.userInterval : Self.automaticInterval
        return now.timeIntervalSince(entry.lastAttempt) >= interval
    }

    mutating func recordSuccess(_ key: String, now: Date) {
        entries[key] = Entry(lastAttempt: now, notBefore: now, failures: 0)
    }

    /// A locally expired credential sent no request; retry on the normal schedule so a
    /// credential renewed by its owner can be picked up without network-error backoff.
    mutating func recordExpiredCredential(_ key: String, now: Date) {
        entries[key] = Entry(lastAttempt: now, notBefore: now, failures: 0)
    }

    /// `jitter` is a factor in 0.8…1.2; `retryAfter` from the server wins over the backoff.
    mutating func recordFailure(_ key: String, now: Date, retryAfter: TimeInterval?, jitter: Double) {
        let failures = (entries[key]?.failures ?? 0) + 1
        let backoff = min(Self.longestBackoff, Self.firstBackoff * pow(2, Double(failures - 1))) * jitter
        let delay = retryAfter.map { max(0, $0) } ?? backoff
        entries[key] = Entry(lastAttempt: now, notBefore: now.addingTimeInterval(delay), failures: failures)
    }

    /// `Retry-After` as delta seconds or an HTTP date.
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
