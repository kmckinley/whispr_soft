//
//  FlowState.swift
//  WhisprSoft
//
//  The single source of truth for pipeline state. Only the Coordinator
//  mutates this; the UI observes it.
//

/// The pipeline's current stage. Equatable so the UI can diff transitions.
enum FlowState: Equatable {
    case idle
    case recording
    case transcribing
    case rewriting
    case injecting
    case error(String)
}
