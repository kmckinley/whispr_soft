//
//  SharedVisuals.swift
//  WhisprSoft
//
//  Visual primitives shared by the menu popover (MenuBarContent) and the
//  on-screen dictation HUD (HUDView/HUDController). Extracted here so both
//  render from one copy of the dark/violet vocabulary — duplicating any of
//  these (e.g. a second Color(hex:) or Theme) would be a redeclaration.
//
//  Everything else in the popover's visual kit (PulseRing, StatusDot,
//  cardSurface, Keycap, …) stays private to MenuBarContent — the HUD doesn't
//  need it.
//

import SwiftUI

// MARK: - Design tokens

enum Theme {
    static let accent = Color(hex: 0x9A8BFF)
    static let accentSoft = Color(hex: 0x9A8BFF, alpha: 0.16)
    static let accentBorder = Color(hex: 0x9A8BFF, alpha: 0.45)
    static let accentGlow = Color(hex: 0x9A8BFF, alpha: 0.40)
    static let violetCheck = Color(hex: 0xB6ABFF)
    static let green = Color(hex: 0x5FD39A)
    static let amber = Color(hex: 0xF5B14C)
    static let red = Color(hex: 0xFF8080)
    static let micTint = Color(hex: 0xCFC9FF)
    static let micDark = Color(hex: 0x6A59E0)
    static let knobDark = Color(hex: 0x171426)
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Reusable subviews

/// Seven staggered waveform bars (recording hero / HUD).
struct WaveformBars: View {
    private let heights: [CGFloat] = [16, 24, 30, 21, 30, 24, 16]
    @State private var animating = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 3, height: heights[i])
                    .scaleEffect(y: animating ? 1 : 0.4, anchor: .center)
                    .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(Double(i) * 0.08),
                               value: animating)
            }
        }
        .onAppear { animating = true }
    }
}

/// A 30pt indeterminate spinner (processing / model-loading hero / HUD).
struct Spinner: View {
    @State private var rotate = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(.linear(duration: 0.7).repeatForever(autoreverses: false), value: rotate)
        }
        .frame(width: 30, height: 30)
        .onAppear { rotate = true }
    }
}
