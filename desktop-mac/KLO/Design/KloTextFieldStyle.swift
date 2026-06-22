import SwiftUI
import AppKit

/// klo's text field. Mirrors the extension's `.input-email` (cream
/// background, hairline ink/15 border, orange border on focus). The
/// only thing that survives from AppKit is the actual NSTextField
/// behavior — every visible default (the system-blue focus ring, the
/// rounded-rect bezel, the 1pt grey border) is hidden behind our own
/// painted background.
///
/// Use it like any other style:
///   TextField("you@email.com", text: $email)
///       .textFieldStyle(KloTextFieldStyle())
///
/// We also flip the textfield's `focusRingType` to `.none` via a
/// hidden NSViewRepresentable side-channel because SwiftUI's
/// `.textFieldStyle` can't reach the underlying NSTextField directly.
struct KloTextFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool

    // SwiftUI requires this exact signature for custom TextFieldStyle.
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.kloBody)
            .foregroundStyle(KloColors.fg)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(KloColors.bgInput)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        focused ? KloColors.orange : KloColors.border,
                        lineWidth: focused ? 1.5 : 1
                    )
            )
            .focused($focused)
            // Hide the system focus ring on the underlying NSTextField.
            .background(NoFocusRingHack())
            .animation(.easeInOut(duration: 0.10), value: focused)
    }
}


// Walks the window's view tree and disables AppKit's default focus
// ring on every NSTextField so our orange border owns the focus signal.
//
// IMPORTANT: walks DOWN only, from the window's contentView, exactly
// once per call. The previous implementation also walked UP via
// `superview` and recursively re-descended at each ancestor — that
// quadruples the work at every level and stack-overflows when the
// host view tree is large (the fullscreen cloud panel triggered this
// reliably).
private struct NoFocusRingHack: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { stripFocusRing(from: v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { stripFocusRing(from: nsView) }
    }
    private func stripFocusRing(from view: NSView) {
        guard let root = view.window?.contentView else { return }
        descend(root)
    }
    private func descend(_ view: NSView) {
        if let tf = view as? NSTextField {
            tf.focusRingType = .none
        }
        for sub in view.subviews {
            descend(sub)
        }
    }
}
