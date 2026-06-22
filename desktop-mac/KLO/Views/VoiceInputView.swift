import SwiftUI

// Voice mode — pure fire. The notch silhouette becomes the fire (in
// KLOOverlayView); AgentClient routes start/stop into RealtimeBridge,
// which opens an OpenAI Realtime WebRTC peer connection that handles
// mic capture, STT, reasoning, TTS, and speaker playback in one stream.
//
// Lifecycle:
//   onAppear    → AgentClient.startVoiceCapture → RealtimeBridge.start
//   onDisappear → AgentClient.stopVoiceCapture  → RealtimeBridge.stop
//   Escape      → state.collapseToIdle (which also triggers onDisappear)
//
// Visual additions:
//   - A tiny "LISTENING / MIC OFF" dot anchored below the notch,
//     bound to `realtimeBridge.micUnmuted`. Gives the user instant
//     feedback on whether the client-side mic gate is currently
//     transmitting their voice to OpenAI (gate open = LISTENING dot
//     pulses olive) or gating ambient room noise (gate closed = small
//     "OFF" glyph). Without this, the user has no way to tell if their
//     soft speech got under the threshold and was filtered out.
struct VoiceInputView: View {
    let onSubmitTranscript: (String) -> Void
    let onSwitchToText: () -> Void

    @EnvironmentObject var state: KLOState
    @EnvironmentObject var agentClient: AgentClient
    @EnvironmentObject var realtimeBridge: RealtimeBridge

    var body: some View {
        ZStack(alignment: .top) {
            // Lifecycle shell — invisible but takes up the full panel
            // so .onAppear / .onDisappear fire reliably on mount cycles.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Stack: progress line above mic indicator.
            // The progress line surfaces `state.currentAction` (the
            // human label klo is doing right now, like "looking at
            // your screen" — already tracked at KLOState.swift:170)
            // so the user has a VISUAL signal even when audio
            // narration hasn't fired yet. Critical for runs that
            // dispatch then go quiet for 2-3s before the first
            // verbal beat.
            VStack(spacing: 6) {
                progressLine
                micIndicator
            }
            .padding(.top, 12)
            .allowsHitTesting(false)
        }
        .onExitCommand { state.collapseToIdle() }
        .onAppear { agentClient.startVoiceCapture() }
        .onDisappear { _ = agentClient.stopVoiceCapture() }
    }

    /// Cream-monospace status line that surfaces the current
    /// `state.currentAction` (the human-readable label of whatever
    /// tool klo is running right now — set in
    /// `KLOState.noteToolActivity`). Visible only when an action is
    /// active; fades out cleanly between states. Pairs with the
    /// audio narration to give the user a continuous "klo is working"
    /// signal even when the model is between verbal beats.
    @ViewBuilder
    private var progressLine: some View {
        if let action = state.currentAction, !action.isEmpty {
            Text(action.uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(KloColors.cream.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .id(action)  // forces transition on action change
        }
    }

    /// "LISTENING" pulsing dot when the mic gate is open (user voice
    /// is reaching OpenAI). "OFF" dim glyph when closed (TV / room
    /// noise is being filtered out — klo doesn't hear it).
    @ViewBuilder
    private var micIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(realtimeBridge.micUnmuted ? KloColors.olive : Color.white.opacity(0.22))
                .frame(width: 6, height: 6)
                .scaleEffect(realtimeBridge.micUnmuted ? 1.15 : 0.85)
                .animation(
                    realtimeBridge.micUnmuted
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .easeInOut(duration: 0.2),
                    value: realtimeBridge.micUnmuted,
                )
            Text(realtimeBridge.micUnmuted ? "LISTENING" : "MIC OFF")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(
                    realtimeBridge.micUnmuted
                        ? KloColors.olive.opacity(0.85)
                        : Color.white.opacity(0.35)
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
                .overlay(
                    Capsule().stroke(
                        realtimeBridge.micUnmuted
                            ? KloColors.olive.opacity(0.30)
                            : Color.white.opacity(0.10),
                        lineWidth: 0.6,
                    )
                )
        )
        .opacity(0.85)
    }
}
