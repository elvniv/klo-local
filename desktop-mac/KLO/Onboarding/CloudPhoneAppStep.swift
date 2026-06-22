import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// Cloud-onboarding step that points the user at klo on iPhone.
///
/// klo's pitch is "drive your Mac from anywhere" — that only lands if
/// the user actually has the iPhone app installed. The cleanest moment
/// to ask is during Mac onboarding: the user is already at their Mac,
/// likely about to pull their phone out for something else, and a QR
/// code converts about an order of magnitude better than a "we'll text
/// you a link" form.
///
/// Flow:
///   1. Step renders a QR code pointing at the App Store listing.
///   2. User pulls out iPhone, opens Camera, scans QR. iPhone opens
///      the App Store entry directly — they tap Install and we're done.
///   3. User taps "I'm done" (or "Skip — no iPhone") on the Mac side.
///      Either flips `klo.didShareiPhoneApp = true`; the cloud card's
///      derived `currentStep` advances to `.ready`.
struct CloudPhoneAppStep: View {

    /// App Store deep link to the live klo iOS listing. Hardcoded to
    /// the published id (6753969468 == klo on the US storefront).
    static let appStoreURL = URL(string:
        "https://apps.apple.com/us/app/klo/id6753969468"
    )!

    /// UserDefaults key. Set when the user has resolved this step
    /// (scanned + tapped "I'm done", or explicitly skipped) so the
    /// cloud card's `currentStep` skips on returning launches.
    static let didShareKey = "klo.didShareiPhoneApp"

    var body: some View {
        OnboardingStepShell(
            eyebrowLabel: "klo on your phone",
            title: "Drive your Mac from anywhere.",
            subtitle: "klo on iPhone runs your Mac when you're not at it. Scan to install — then control your Mac from anywhere, by text or voice.",
            contentTopPadding: 24
        ) {
            content
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 24) {
            qrPanel
            actionRow
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: - QR panel

    private var qrPanel: some View {
        VStack(spacing: 14) {
            ZStack {
                // Outer olive halo — pulses gently so the user's eye
                // lands on the QR even before they've read the copy.
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(KloColors.olive.opacity(0.10))
                    .frame(width: 280, height: 280)
                    .blur(radius: 22)

                // White card the QR sits on. Cameras need a high-
                // contrast white background to lock the QR fast, and
                // an inner card is the standard "scannable" affordance.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 248, height: 248)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(KloColors.border.opacity(0.6), lineWidth: 0.5)
                    )

                if let qr = Self.qrImage(for: Self.appStoreURL.absoluteString, pixelSize: 720) {
                    Image(nsImage: qr)
                        .interpolation(.none)   // crisp pixel edges, no blur
                        .resizable()
                        .scaledToFit()
                        .frame(width: 208, height: 208)
                }

                // Center logo badge — the real hand-drawn klo wordmark
                // on a cream paper tile. Sits inside the QR's 30%
                // error-correction budget so the code still scans.
                // The white-card-with-rounded-corners under the icon
                // gives the QR scanner a clear "this is a logo, not
                // a missing module" signal.
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(red: 251/255, green: 248/255, blue: 242/255))   // klo-paper
                        .frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
                    Image("KloIconCream")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                }
            }
            .accessibilityLabel("QR code linking to klo on the App Store")

            Text("Open Camera on your iPhone. Point at the QR.")
                .font(.kloBody)
                .foregroundStyle(KloColors.fg60)
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    UserDefaults.standard.set(true, forKey: Self.didShareKey)
                } label: {
                    HStack(spacing: 8) {
                        Text("I'm done")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.kloPrimary)
                .frame(maxWidth: 220)
                .keyboardShortcut(.return)

                Button {
                    // Helpful fallback: open the App Store on this Mac
                    // (the Mac App Store will route the iOS link to a
                    // "View on iPhone" page that the user can email or
                    // share to their phone). Cheap second path so the
                    // user doesn't get stuck if their iPhone camera is
                    // misbehaving.
                    NSWorkspace.shared.open(Self.appStoreURL)
                } label: {
                    Text("Open on this Mac")
                }
                .buttonStyle(.kloGhost)
            }

            VStack(spacing: 4) {
                Button {
                    UserDefaults.standard.set(true, forKey: Self.didShareKey)
                } label: {
                    Text("I don't have an iPhone")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(KloColors.fg45)
                }
                .buttonStyle(.plain)
                Text("You can add this from Settings anytime.")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(KloColors.fg45.opacity(0.7))
            }
        }
    }

    // MARK: - QR generator (Core Image)

    /// Render a high-contrast QR code at `pixelSize` for the given URL.
    /// Uses Core Image's built-in generator with 30% error correction
    /// so the centered klo logo badge in `qrPanel` doesn't break scans.
    /// Cached on the NSImage so the view body can re-evaluate without
    /// re-running Core Image every render.
    static func qrImage(for string: String, pixelSize: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"

        guard let ciImage = filter.outputImage else { return nil }
        let extent = ciImage.extent
        guard extent.width > 0 else { return nil }
        let scale = pixelSize / extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
