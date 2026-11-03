//
//  SingleFlight.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation

/// Runs one asynchronous load at a time.
///
/// A request while a load runs is queued, or dropped with `queueIfBusy: false`; the newest queued
/// request replaces an older one and starts once the current load has been applied. `apply` runs
/// after `isRunning` turns false, so it can show the finished state.
@MainActor
final class SingleFlight {
    private var task: Task<Void, Never>?
    private var queued: (() -> Void)?

    var isRunning: Bool { task != nil }

    func run<Value: Sendable>(
        queueIfBusy: Bool = true, _ load: @escaping @Sendable () async -> Value,
        then apply: @escaping (Value) -> Void
    ) {
        guard task == nil else {
            if queueIfBusy { queued = { [weak self] in self?.run(load, then: apply) } }
            return
        }
        task = Task { [weak self] in
            let value = await load()
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            apply(value)
            if let next = self.queued {
                self.queued = nil
                next()
            }
        }
    }

    /// Drops the queued request and abandons the running load; its result is never applied.
    func cancel() {
        task?.cancel()
        task = nil
        queued = nil
    }
}
