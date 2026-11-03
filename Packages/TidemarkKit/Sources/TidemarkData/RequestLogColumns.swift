//
//  RequestLogColumns.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation

public enum RequestLogColumn: String, CaseIterable, Codable, Sendable {
    case app, provider, model, cost, freshInput, output, cacheHit, cacheWrite
    case hitRate, speed, firstToken, totalTime, statusCode
}

/// Time is deliberately outside the configurable order: always first and visible.
public struct RequestLogColumns: Equatable, Sendable {
    public private(set) var order: [RequestLogColumn]
    public private(set) var hidden: Set<RequestLogColumn>
    private static let defaults: Set<RequestLogColumn> = [.app, .model, .speed, .firstToken, .totalTime]
    public static let standard = Self()
    public var visible: [RequestLogColumn] { order.filter { !hidden.contains($0) } }

    public init(storedOrder: [String]? = nil, storedHidden: [String]? = nil) {
        var seen: Set<RequestLogColumn> = []
        order = (storedOrder ?? []).compactMap(RequestLogColumn.init).filter { seen.insert($0).inserted }
        let newlyAdded = Set(RequestLogColumn.allCases).subtracting(seen)
        // Insert missing/new cases at their canonical slot without disturbing saved relative order.
        for (index, column) in RequestLogColumn.allCases.enumerated() where newlyAdded.contains(column) {
            order.insert(column, at: min(index, order.count))
        }
        hidden = Set((storedHidden ?? []).compactMap(RequestLogColumn.init))
        if storedHidden == nil {
            hidden = Set(RequestLogColumn.allCases).subtracting(Self.defaults)
        } else {
            hidden.formUnion(newlyAdded.subtracting(Self.defaults))
        }
    }

    public mutating func setVisible(_ visible: Bool, _ column: RequestLogColumn) {
        if visible { hidden.remove(column) } else { hidden.insert(column) }
    }

    /// Like `onMove`, destination is the index before removal; hidden columns retain their relative order.
    public mutating func move(_ column: RequestLogColumn, to index: Int) {
        guard let source = order.firstIndex(of: column) else { return }
        let destination = min(max(0, index), order.count)
        order.remove(at: source)
        order.insert(column, at: destination - (source < destination ? 1 : 0))
    }

    public mutating func move(_ column: RequestLogColumn, toVisibleIndex index: Int) {
        let others = visible.filter { $0 != column }
        let target = index < others.count ? order.firstIndex(of: others[max(0, index)])! : order.count
        move(column, to: target)
    }

    public mutating func reset() { self = .standard }
}
