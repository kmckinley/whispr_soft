//
//  Log.swift
//  WhisprSoft
//
//  Shared unified-logging entry point. Components log via these Loggers so
//  diagnostics are readable from the real Finder-launched app (print() output
//  from a GUI app isn't visible in Console). Add categories here as needed.
//

import os

/// `nonisolated` so loggers are reachable from any context — including the
/// audio-thread tap callback — under the project's MainActor default isolation.
/// `Logger` is immutable and Sendable, so this is safe.
nonisolated enum Log {
    static let capture = Logger(
        subsystem: "com.whisprsoft",  // = bundle id
        category: "capture"
    )

    static let hotkey = Logger(
        subsystem: "com.whisprsoft",
        category: "hotkey"
    )

    static let pipeline = Logger(
        subsystem: "com.whisprsoft",
        category: "pipeline"
    )

    static let transcription = Logger(
        subsystem: "com.whisprsoft",
        category: "transcription"
    )

    static let rewrite = Logger(
        subsystem: "com.whisprsoft",
        category: "rewrite"
    )

    static let correction = Logger(
        subsystem: "com.whisprsoft",
        category: "correction"
    )

    static let injection = Logger(
        subsystem: "com.whisprsoft",
        category: "injection"
    )
}
