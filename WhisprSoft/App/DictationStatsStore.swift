//
//  DictationStatsStore.swift
//  WhisprSoft
//
//  Long-horizon activity counts — how many dictations the user delivered, per
//  day, for a Settings activity graph. Distinct from `DictationLogStore`, whose
//  100-entry ring buffer can't back a 90-day view: this store keeps only a
//  day-keyed COUNT map (plus dates), no per-run detail, so it's tiny and can
//  span months.
//
//  Persisted to UserDefaults (JSON), loaded at launch. Like the log, persistence
//  is privacy-safe because the store holds ONLY counts and day keys — never any
//  transcript content, so no dictated text ever reaches disk. The Coordinator
//  increments it once per delivered dictation (the success path only).
//

import Foundation
import Observation

/// One bucket of the charted series (a day, week, or month) with its summed
/// count. `Identifiable` for SwiftUI/Charts; the `id` is session-only list
/// identity and is never persisted.
struct StatBucket: Identifiable, Sendable {
    let id = UUID()
    let start: Date
    let count: Int
}

/// The chart's bucketing granularity. Raw-value-backed so it round-trips through
/// `@AppStorage`.
enum StatsGranularity: String, CaseIterable, Sendable {
    case day, week, month
}

/// Holds per-day dictation counts (a `"yyyy-MM-dd"` → count map). Owned by
/// `AppDelegate`, mirroring the other `@MainActor @Observable` stores; the
/// Coordinator writes (one increment per delivered dictation), the Settings
/// view reads (bucketed series for the activity graph).
@MainActor
@Observable
final class DictationStatsStore {
    /// Persisted JSON map (counts only — no transcript content, so safe to write
    /// to disk). Mirrors DictationLogStore's persistence pattern.
    nonisolated static let storageKey = "dictationStats"

    /// Trailing window the graph covers, in days (today plus the prior 89).
    static let windowDays = 90

    /// Day keys older than this are pruned on write — cheap, and future-proofs
    /// beyond the 90-day window without unbounded growth.
    private static let retentionDays = 365

    /// `"yyyy-MM-dd"` day key → count. Seeded from the persisted map via a
    /// nonisolated default initializer, so a nonisolated `init()` (needed for the
    /// Coordinator's default arguments) can construct the store without touching
    /// the MainActor-isolated property body.
    private(set) var counts: [String: Int] = DictationStatsStore.loadCounts()

    /// Stable day-key formatter. A plain `static let` is MainActor-isolated under
    /// the project's default isolation; it's touched only by the MainActor
    /// `recordDictation`/`series`, so it never crosses an isolation boundary and
    /// needs no `nonisolated` escape hatch. `en_US_POSIX` + a fixed pattern keeps
    /// the key locale-stable; the current calendar/timezone defines "the day".
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Nonisolated so it can construct in the Coordinator's default arguments
    /// (the same pattern the other injected stores use).
    nonisolated init() {}

    /// Count one delivered dictation against its day. Increments that day's
    /// count, prunes entries older than the retention window, and persists.
    /// Called on the Coordinator's success path only.
    func recordDictation(at date: Date = Date()) {
        let key = Self.dayFormatter.string(from: Self.startOfDay(date))
        counts[key, default: 0] += 1
        prune()
        save()
    }

    // MARK: - Read API (charting)

    /// A bucketed series over the trailing 90-day window
    /// (`startOfDay(today) - 89 days … today`):
    /// - `.day`   — one bucket per day, zero-filled so the axis is continuous.
    /// - `.week`  — the window's days grouped into calendar weeks; each bucket
    ///   sums its days; `start` is the week's start.
    /// - `.month` — grouped into calendar months; summed; `start` is the month
    ///   start.
    /// Week/month buckets are built by iterating the same day set, so their sums
    /// equal the underlying day totals.
    func series(_ granularity: StatsGranularity) -> [StatBucket] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let windowStart = cal.date(byAdding: .day,
                                         value: -(Self.windowDays - 1),
                                         to: today) else { return [] }

        switch granularity {
        case .day:
            return (0..<Self.windowDays).compactMap { offset in
                guard let day = cal.date(byAdding: .day, value: offset, to: windowStart)
                else { return nil }
                return StatBucket(start: day, count: counts[Self.dayFormatter.string(from: day)] ?? 0)
            }
        case .week, .month:
            let component: Calendar.Component = granularity == .week ? .weekOfYear : .month
            // Preserve first-seen bucket order; sum each bucket's member days.
            var order: [Date] = []
            var sums: [Date: Int] = [:]
            for offset in 0..<Self.windowDays {
                guard let day = cal.date(byAdding: .day, value: offset, to: windowStart),
                      let bucketStart = cal.dateInterval(of: component, for: day)?.start
                else { continue }
                if sums[bucketStart] == nil { order.append(bucketStart) }
                sums[bucketStart, default: 0] += counts[Self.dayFormatter.string(from: day)] ?? 0
            }
            return order.map { StatBucket(start: $0, count: sums[$0] ?? 0) }
        }
    }

    // MARK: - Persistence

    private static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// Drop keys older than the retention window. Keys are zero-padded
    /// `"yyyy-MM-dd"`, so lexicographic order is date order — comparing strings
    /// avoids parsing every key back to a Date.
    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day,
                                                 value: -Self.retentionDays,
                                                 to: Self.startOfDay(Date())) else { return }
        let cutoffKey = Self.dayFormatter.string(from: cutoff)
        counts = counts.filter { $0.key >= cutoffKey }
    }

    /// Persist the current map as JSON. Called after every mutation.
    private func save() {
        guard let data = try? JSONEncoder().encode(counts) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Restore the persisted map; on absence or a decode failure, return empty
    /// (stats were never persisted before, so no migration is needed).
    /// Nonisolated so the nonisolated init can call it.
    private nonisolated static func loadCounts() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return decoded
    }
}
