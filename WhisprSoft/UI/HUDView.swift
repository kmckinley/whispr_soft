//
//  HUDView.swift
//  WhisprSoft
//
//  The compact on-screen dictation indicator — a small horizontal pill shown
//  near the top-center of the active screen while a dictation runs, so the user
//  gets feedback (and sees the active tone) even when the menu popover is closed
//  and they're dictating into another app.
//
//  Pure observer: it renders from `coordinator.state` + `coordinator.activeToneName`
//  and never pushes anything back to the Coordinator. HUDController owns the
//  panel and drives show/hide/position; this view just draws the current state.
//

import SwiftUI

struct HUDView: View {
    let coordinator: Coordinator

    var body: some View {
        // Sized to its content (the controller resizes the panel to fittingSize),
        // so the pill grows/shrinks with the tone name and state text.
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 40)
            .background(pill)
            .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .recording:
            HStack(spacing: 10) {
                WaveformBars()
                    .scaleEffect(0.66, anchor: .center)   // ~30pt bars → ~20pt tall
                    .frame(width: 24, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Listening")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                    if let tone = coordinator.activeToneName {
                        Text(tone)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        case .transcribing, .rewriting, .injecting:
            HStack(spacing: 10) {
                Spinner()
                    .scaleEffect(0.6, anchor: .center)
                    .frame(width: 20, height: 20)
                Text("Cleaning up…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
            }
        case .error(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.red)
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Bound the width so tail-truncation actually engages — the
                    // outer .fixedSize() would otherwise give the text unbounded
                    // width and a long error would stretch the pill across the screen.
                    .frame(maxWidth: 260, alignment: .leading)
            }
        case .idle:
            // The controller orders the panel out on idle; render nothing.
            EmptyView()
        }
    }

    /// Dark translucent capsule with a subtle accent border and a drawn shadow
    /// (the panel itself has `hasShadow = false`), legible over any background.
    private var pill: some View {
        Capsule()
            .fill(Theme.knobDark.opacity(0.92))
            .overlay(Capsule().strokeBorder(Theme.accentBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
    }
}
