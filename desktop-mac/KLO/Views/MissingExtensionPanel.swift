import SwiftUI

/// Branded "klo needs the Chrome extension for that" card. Replaces
/// what used to be a salmon `RuntimeError: extension not connected …`
/// string in the result panel — gives the user actual escape hatches:
/// **Install** opens the Web Store listing, **Retry** re-runs the
/// original prompt the moment the bridge sees Chrome come online.
///
/// Lives in the same 600×360 panel slot ResultPanelView lives in (per
/// `KLOOverlayView.surfaceDimensions`), so the notch geometry doesn't
/// flicker between modes.
struct MissingExtensionPanel: View {
    let query: String
    /// The agent's final message when the run still completed
    /// gracefully without the extension (e.g. "I can't read that tab
    /// without the extension"). Shown above the install CTA so the
    /// reply isn't lost behind the card.
    var response: String? = nil
    let onDismiss: () -> Void
    let onRetry: (String) -> Void

    @EnvironmentObject var bridge: BridgeStatusManager
    @State private var appeared: Bool = false
    @State private var hovering: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Tiny mono prompt label, same shape as ResultPanelView's,
            // so the user reads the panel as "your prompt landed but…"
            Text(query)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .tracking(0.4)
                .textCase(.lowercase)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(query)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -4)
                .animation(.easeOut(duration: 0.32).delay(0.00), value: appeared)

            // The agent's graceful reply, when the run completed
            // without the tool. Same plain-text treatment the chat
            // panel uses for klo's responses — no eyebrow, the panel
            // IS klo.
            if let response, !response.isEmpty {
                Text(response)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(4)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 4)
                    .animation(.easeOut(duration: 0.36).delay(0.05), value: appeared)
            }

            // Eyebrow + headline + lede.
            VStack(alignment: .leading, spacing: 10) {
                eyebrow

                Text("klo needs the Chrome extension for that.")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.96))
                    .fixedSize(horizontal: false, vertical: true)

                Text(bridge.chromeInstalled
                     ? "Install it once and klo can drive any tab. We'll re-run your prompt the moment it's ready."
                     : "Install Google Chrome first, then add the klo extension. We'll re-run your prompt the moment it's ready.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)
            .animation(.easeOut(duration: 0.40).delay(0.10), value: appeared)

            // Action row.
            HStack(spacing: 10) {
                installButton
                retryButton
                Spacer()
            }
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.32).delay(0.18), value: appeared)

            Spacer(minLength: 0)

            footer
                .opacity(appeared ? 0.85 : 0)
                .animation(.easeOut(duration: 0.32).delay(0.26), value: appeared)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { hovering = $0 }
        .onExitCommand { onDismiss() }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { appeared = true }
            // Force a quick re-poll so the Retry button enables fast
            // if the user just had to bring Chrome to the foreground.
            bridge.recheck()
        }
    }

    private var eyebrow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(KloColors.orange)
                .frame(width: 6, height: 6)
                .shadow(color: KloColors.orange.opacity(0.55), radius: 4)
            // Don't blame the extension when klo's own agent process
            // is down — the /health poll distinguishes the two.
            Text(bridge.sidecarReachable
                 ? "browser extension · not connected"
                 : "klo agent · not running")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var installButton: some View {
        Button {
            bridge.openInstall()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                // openInstall routes to the Chrome download page when
                // Chrome itself is missing — label matches the action.
                Text(bridge.chromeInstalled ? "Install" : "Get Google Chrome")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(KloColors.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(KloColors.orange)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private var retryButton: some View {
        let enabled = bridge.extensionConnected
        Button {
            guard enabled else { return }
            onRetry(query)
        } label: {
            HStack(spacing: 8) {
                if !enabled {
                    Circle()
                        .fill(KloColors.orange)
                        .frame(width: 5, height: 5)
                        .modifier(_PulseDot())
                }
                Text(enabled ? "Retry"
                     : bridge.sidecarReachable ? "Waiting for Chrome…"
                     : "Waiting for klo's agent…")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(enabled ? .white.opacity(0.96) : .white.opacity(0.50))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(enabled ? 0.10 : 0.04))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(enabled ? 0.22 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onDismiss) {
                HStack(spacing: 4) {
                    Text("esc")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                    Text("dismiss")
                        .font(.system(size: 10, weight: .regular))
                }
                .foregroundStyle(.white.opacity(hovering ? 0.46 : 0.22))
            }
            .buttonStyle(.plain)
        }
    }
}

// Tiny pulsing-dot modifier so the "Waiting for Chrome…" state has a
// quiet sign-of-life signal without animating the whole button. Same
// 1.4s ease-in-out cadence as the side-panel header pulse in the
// extension.
private struct _PulseDot: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 0.05)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * (.pi * 2 / 1.4)) + 1) / 2  // 0…1
            let opacity = 0.30 + (phase * 0.70)             // 0.30…1.00
            content.opacity(opacity)
        }
    }
}
