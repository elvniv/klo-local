import SwiftUI
import AppKit

/// Inline Composio connections browser, rendered inside the notch
/// overlay when `state.mode == .connections`. Raycast / Arc Spaces
/// style: search bar at top, featured row of 8 hero tiles, then a
/// dense all-apps grid for the rest of Composio's catalog.
///
/// Connected toolkits wear the same breathing olive halo as the
/// dormant notch (KloFireGlow), so every "klo is alive" surface in
/// the product reads with one visual vocabulary.
///
/// Size matches Completed-compact (760×500) so it never overflows on
/// 13" MBPs. The outer VStack is explicitly width-constrained so
/// SwiftUI can't grow content past the surface mask.
struct ConnectionsView: View {

    // Surface bounds — kept in sync with KLOOverlayView's
    // surfaceDimensions case for .connections. Explicit constants here
    // so the LazyVGrid / spacing math is self-contained and obvious.
    private static let surfaceWidth: CGFloat = 760
    private static let surfaceHeight: CGFloat = 500
    private static let horizontalInset: CGFloat = 20

    // Featured tiles laid out as 2 rows × 4 columns so the row never
    // overflows the notch panel's width regardless of which display
    // the user is on. 8 tiles × 76pt + 7 × 12pt spacing nominally fits
    // 760pt, but the panel's NotchShape mask + horizontal insets shave
    // 30-40pt off the usable width on some setups, and the first/last
    // tiles get clipped. A 2×4 grid is 4 × 76 + 3 × 12 = 340pt wide —
    // comfortable under any reasonable surface width.
    private static let featuredTileSize: CGFloat = 76
    private static let featuredTileSpacing: CGFloat = 12

    /// Wrap a Composio SVG URL with the images.weserv.nl proxy so it
    /// comes back as a small PNG that AsyncImage / NSImage can actually
    /// decode. Composio's CDN only serves image/svg+xml, which NSImage
    /// doesn't render natively; routing through weserv (free, cached on
    /// their CDN) sidesteps the decode without bundling an SVG library.
    static func rasterIconURL(for raw: URL?, size: Int = 128) -> URL? {
        guard let raw = raw else { return nil }
        let stripped = raw.absoluteString
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let encoded = stripped.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? stripped
        return URL(string: "https://images.weserv.nl/?url=\(encoded)&output=png&w=\(size)&h=\(size)")
    }
    private static let compactTileSize: CGFloat = 56
    private static let compactTileSpacing: CGFloat = 8

    private let featuredColumns: [GridItem] = Array(
        repeating: GridItem(
            .fixed(76),
            spacing: 12,
            alignment: .top,
        ),
        count: 4,
    )

    @ObservedObject var account: AccountManager
    /// Pre-filled search string, used when /apps was invoked with a
    /// trailing query (`/apps gmail`).
    var initialQuery: String = ""
    var onDismiss: () -> Void = {}

    /// Featured tiles in the hero row. Order is the order they appear.
    /// Curated for v0 — covers ~80% of typical workflows. Browse-all
    /// grid below carries the rest of Composio's 300+ catalog.
    // Slugs must match Composio's v3 catalog exactly (case-sensitive).
    // Verified 2026-05-28: gcalendar → googlecalendar, drive → googledrive.
    private static let featured: [String] = [
        "gmail", "googlecalendar", "slack", "notion",
        "linear", "github", "asana", "googledrive",
    ]

    @State private var catalog: [ComposioApp] = []
    @State private var loadError: String? = nil
    @State private var loadErrorIsConfigGap: Bool = false
    @State private var loadErrorIsAuth: Bool = false
    @State private var isLoading: Bool = false
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    /// Adaptive all-apps grid — fits as many ~56pt tiles as the
    /// content area allows. Avoids hardcoding column counts that
    /// can overflow at narrower widths.
    private let allAppsColumns: [GridItem] = [
        GridItem(
            .adaptive(minimum: 56, maximum: 72),
            spacing: ConnectionsView.compactTileSpacing,
            alignment: .top,
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchHeader
                .padding(.horizontal, Self.horizontalInset)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider().background(KloColors.border)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            footerHints
                .padding(.horizontal, Self.horizontalInset)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55))
        }
        .frame(width: Self.surfaceWidth, height: Self.surfaceHeight, alignment: .top)
        .background(Color.black)
        .clipped()
        .onAppear {
            query = initialQuery
            searchFocused = true
        }
        .task { await loadCatalogIfNeeded() }
        // Esc → dismiss. Wired via .background NSEvent monitor so it
        // fires regardless of which subview currently holds focus.
        .background(EscapeKeyCatcher(onEscape: onDismiss))
    }

    // MARK: - Search header

    @ViewBuilder
    private var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(KloColors.cream.opacity(0.55))

            TextField("find an app to connect…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(KloColors.cream)
                .tint(KloColors.olive)
                .focused($searchFocused)
                .onSubmit { handleSubmitFromSearch() }

            Spacer(minLength: 8)

            // Connected counter — only meaningful once catalog has
            // loaded. Fades in/out so it doesn't flash a "0 of 0" frame.
            if !catalog.isEmpty {
                Text("\(account.connectedToolkits.count)/\(catalog.count) connected")
                    .font(.kloEyebrow)
                    .foregroundStyle(KloColors.fg60)
                    .tracking(1.0)
                    .textCase(.uppercase)
            }
        }
    }

    // MARK: - Body content (one of: loading, error/empty-state, normal)

    @ViewBuilder
    private var content: some View {
        if loadErrorIsConfigGap {
            // Composio isn't configured server-side. Replace the entire
            // body with a centered empty state so the panel doesn't
            // read as broken.
            configurationGapView
                .padding(.horizontal, Self.horizontalInset)
        } else if loadErrorIsAuth {
            // Token expired AND the reactive refresh in authedPOST also
            // failed (refresh token revoked / Mac slept past both windows).
            // Don't show "HTTP 401" — show a clear reconnect prompt.
            authExpiredView
                .padding(.horizontal, Self.horizontalInset)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    featuredSection
                    allAppsSection
                }
                .padding(.horizontal, Self.horizontalInset)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
        }
    }

    /// Centered empty state when the user's session expired *and* the
    /// reactive refresh couldn't recover (refresh token also gone). Asks
    /// the user to sign back in via the existing OAuth flow. Matches the
    /// visual language of `configurationGapView` so the modal reads as
    /// "klo's still here, just needs a hand" rather than broken.
    @ViewBuilder
    private var authExpiredView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "lock.rotation")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(KloColors.olive.opacity(0.7))

            VStack(spacing: 6) {
                Text("session expired")
                    .font(.kloTitle)
                    .foregroundStyle(KloColors.cream)
                Text("Your sign-in needs a refresh before connected apps can load. One click and you're back in.")
                    .font(.kloBody)
                    .foregroundStyle(KloColors.fg60)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await account.startSignInWithGoogle() }
                } label: {
                    Label("Sign in with Google", systemImage: "g.circle.fill")
                        .font(.kloBodyEmphasis)
                }
                .buttonStyle(.kloGhost)

                Button {
                    Task { await loadCatalogIfNeeded(force: true) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.kloBodyEmphasis)
                }
                .buttonStyle(.kloGhost)
            }
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Featured row

    @ViewBuilder
    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionEyebrow("FEATURED")
            if filteredFeatured.isEmpty && !query.isEmpty {
                Text("no featured matches — try the full list below")
                    .font(.kloCaption)
                    .foregroundStyle(KloColors.fg45)
            } else {
                // 2 rows × 4 columns, fixed tile size. Wrapped in
                // Spacer-flanked HStack so the grid sits visually
                // centered inside the notch's curved surface — fixed
                // left-alignment read as off-balance against the
                // symmetrical panel rounding.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LazyVGrid(columns: featuredColumns, alignment: .center,
                              spacing: Self.featuredTileSpacing) {
                        ForEach(filteredFeatured, id: \.slug) { app in
                            FeaturedTile(
                                app: app,
                                size: Self.featuredTileSize,
                                isConnected: account.connectedToolkits.contains(app.slug),
                                isConnecting: account.connectingToolkit == app.slug,
                                onTap: { toggleConnection(for: app) },
                            )
                        }
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - All apps grid

    @ViewBuilder
    private var allAppsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Eyebrow + count — shows "ALL APPS · 287" when catalog
            // loaded so the user has a sense of scale and the section
            // doesn't read as "broken / empty" while loading or when
            // a search filters everything out.
            HStack(spacing: 8) {
                sectionEyebrow("ALL APPS")
                if !catalog.isEmpty {
                    Text("·")
                        .font(.kloEyebrow)
                        .foregroundStyle(KloColors.fg45)
                    Text("\(filteredAllApps.count) of \(nonFeaturedTotal)")
                        .font(.kloEyebrow)
                        .foregroundStyle(KloColors.fg45)
                        .tracking(1.0)
                }
            }
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(KloColors.olive)
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if let err = loadError, !loadErrorIsConfigGap {
                Text(err)
                    .font(.kloCaption)
                    .foregroundStyle(KloColors.fg45)
                    .padding(.vertical, 12)
            } else if filteredAllApps.isEmpty {
                Text(query.isEmpty
                     ? "no additional services available yet"
                     : "no matches — try a different search")
                    .font(.kloCaption)
                    .foregroundStyle(KloColors.fg45)
                    .padding(.vertical, 12)
            } else {
                LazyVGrid(columns: allAppsColumns, alignment: .leading,
                          spacing: Self.compactTileSpacing) {
                    ForEach(filteredAllApps, id: \.slug) { app in
                        CompactTile(
                            app: app,
                            size: Self.compactTileSize,
                            isConnected: account.connectedToolkits.contains(app.slug),
                            isConnecting: account.connectingToolkit == app.slug,
                            onTap: { toggleConnection(for: app) },
                        )
                    }
                }
            }
        }
    }

    // MARK: - Configuration-gap empty state

    @ViewBuilder
    private var configurationGapView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(KloColors.olive.opacity(0.7))

            VStack(spacing: 6) {
                Text("connections aren't configured yet")
                    .font(.kloTitle)
                    .foregroundStyle(KloColors.cream)
                Text("klo's cloud is missing the COMPOSIO_API_KEY environment variable. Once it's set, all 300+ services will appear here.")
                    .font(.kloBody)
                    .foregroundStyle(KloColors.fg60)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: "https://app.composio.dev") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Composio dashboard", systemImage: "arrow.up.right")
                        .font(.kloBodyEmphasis)
                }
                .buttonStyle(.kloGhost)

                Button {
                    Task { await loadCatalogIfNeeded(force: true) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.kloBodyEmphasis)
                }
                .buttonStyle(.kloGhost)
            }
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer hints

    @ViewBuilder
    private var footerHints: some View {
        HStack(spacing: 16) {
            footerHintItem(symbol: "esc", label: "dismiss")
            footerHintItem(symbol: "/", label: "search")
            footerHintItem(symbol: "↩", label: "connect")
            Spacer(minLength: 0)
        }
    }

    private func footerHintItem(symbol: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(symbol)
                .font(.kloMono)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(KloColors.border, lineWidth: 0.5),
                )
                .foregroundStyle(KloColors.fg80)
            Text(label)
                .font(.kloCaption)
                .foregroundStyle(KloColors.fg60)
        }
    }

    private func sectionEyebrow(_ text: String) -> some View {
        Text(text)
            .font(.kloEyebrow)
            .tracking(1.4)
            .foregroundStyle(KloColors.fg60)
    }

    // MARK: - Filtering

    private var filteredFeatured: [ComposioApp] {
        let apps = Self.featured.map { resolveOrSynthesize(slug: $0) }
        return filtered(apps)
    }

    private var filteredAllApps: [ComposioApp] {
        return filtered(nonFeaturedApps)
    }

    /// All catalog apps minus the featured eight — the population the
    /// all-apps grid renders before any search filter is applied. Used
    /// by the header count so the user sees "12 of 287" rather than
    /// "12 of 12" when typing into the search.
    private var nonFeaturedApps: [ComposioApp] {
        let featuredSet = Set(Self.featured)
        return catalog.filter { !featuredSet.contains($0.slug) }
    }

    private var nonFeaturedTotal: Int { nonFeaturedApps.count }

    private func filtered(_ apps: [ComposioApp]) -> [ComposioApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return apps }
        return apps.filter {
            $0.slug.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    /// If the catalog has an entry for `slug`, use it; otherwise
    /// synthesize a minimal ComposioApp so featured tiles render
    /// instantly on first paint (before the network call completes).
    private func resolveOrSynthesize(slug: String) -> ComposioApp {
        if let hit = catalog.first(where: { $0.slug == slug }) { return hit }
        return ComposioApp(
            slug: slug,
            name: slug.replacingOccurrences(of: "_", with: " ").capitalized,
            description: "",
            iconURL: nil,
        )
    }

    // MARK: - Actions

    private func toggleConnection(for app: ComposioApp) {
        if account.connectedToolkits.contains(app.slug) {
            account.disconnectComposio(toolkit: app.slug)
        } else if account.connectingToolkit != app.slug {
            account.startComposioConnect(toolkit: app.slug)
        }
    }

    /// Pressing Return in the search field: if there's exactly one
    /// match across all visible apps, trigger its connection.
    /// Otherwise no-op (lets the search field keep filtering).
    private func handleSubmitFromSearch() {
        let combined = filteredFeatured + filteredAllApps
        guard combined.count == 1, let only = combined.first else { return }
        toggleConnection(for: only)
    }

    @MainActor
    private func loadCatalogIfNeeded(force: Bool = false) async {
        if !force {
            guard catalog.isEmpty, !isLoading else { return }
        }
        isLoading = true
        defer { isLoading = false }
        // Reset all error flags on every attempt so retry from a stale
        // state never lingers (e.g. retry from authExpired succeeds →
        // the empty-state view shouldn't keep showing).
        self.loadErrorIsConfigGap = false
        self.loadErrorIsAuth = false
        do {
            let apps = try await account.fetchComposioCatalog()
            self.catalog = apps
            self.loadError = nil
        } catch let err as ComposioError {
            switch err {
            case .notConfigured:
                self.loadError = "Composio isn't set up on this server yet — `COMPOSIO_API_KEY` is missing."
                self.loadErrorIsConfigGap = true
            case .authExpired:
                self.loadError = err.errorDescription
                self.loadErrorIsAuth = true
            case .subscriptionRequired:
                self.loadError = "Connecting apps is a Pro feature."
            default:
                self.loadError = err.errorDescription
            }
        } catch {
            self.loadError = "Couldn't load the integrations catalog."
        }
    }
}


// MARK: - BrandStyle (smart monogram + per-service color)
//
// Composio's catalog returns icon URLs, but they don't always load —
// occasionally 404, sometimes blocked by ATS for http:// URLs, and the
// AsyncImage cache misses on every cold launch. The fallback monogram
// is therefore the *de facto* visible tile most of the time.
//
// Three things make the fallback feel deliberate instead of placeholder:
//   1. Smart initials. "Google Calendar" → "GC", not "GO". "GitHub"
//      → "GH". For single-word names, take first 2 letters.
//   2. Per-service colors. Each slug deterministically maps to one of
//      12 palette colors chosen to read against the modal's dark
//      background. Identical slugs always get the same color, so the
//      user learns "Gmail = red-ish, Slack = magenta" by sight.
//   3. Friendly humanized name override for the curated featured set
//      so we never render "Googlecale…" even before the catalog loads.
enum BrandStyle {
    /// 12-color palette tuned for the dark notch modal. Brand-adjacent
    /// without imitating any specific service's official color. Pure
    /// HSL spread so adjacent slugs land on visibly different hues.
    private static let palette: [Color] = [
        Color(red: 0.94, green: 0.45, blue: 0.42),  // coral
        Color(red: 0.96, green: 0.66, blue: 0.34),  // amber
        Color(red: 0.90, green: 0.80, blue: 0.36),  // canary
        Color(red: 0.58, green: 0.80, blue: 0.42),  // moss
        Color(red: 0.38, green: 0.78, blue: 0.62),  // teal
        Color(red: 0.34, green: 0.68, blue: 0.88),  // sky
        Color(red: 0.46, green: 0.50, blue: 0.92),  // indigo
        Color(red: 0.70, green: 0.46, blue: 0.92),  // violet
        Color(red: 0.92, green: 0.46, blue: 0.78),  // pink
        Color(red: 0.84, green: 0.56, blue: 0.40),  // terracotta
        Color(red: 0.50, green: 0.74, blue: 0.74),  // sage
        Color(red: 0.78, green: 0.72, blue: 0.52),  // sand
    ]

    /// Humanized names for slugs the catalog might return as one jammed
    /// word ("googlecalendar" → "Google Calendar"). Falls back to a
    /// spaced + Title Case version of the slug.
    private static let nameOverrides: [String: String] = [
        "gmail": "Gmail",
        "googlecalendar": "Google Calendar",
        "googledrive": "Google Drive",
        "googlesheets": "Google Sheets",
        "googledocs": "Google Docs",
        "slack": "Slack",
        "notion": "Notion",
        "linear": "Linear",
        "github": "GitHub",
        "gitlab": "GitLab",
        "asana": "Asana",
        "trello": "Trello",
        "jira": "Jira",
        "discord": "Discord",
        "zoom": "Zoom",
        "dropbox": "Dropbox",
        "salesforce": "Salesforce",
        "hubspot": "HubSpot",
        "stripe": "Stripe",
        "twilio": "Twilio",
    ]

    /// Friendly display name. Prefers the catalog's name when it
    /// already has spaces; otherwise looks up the override map; falls
    /// back to a humanized version of the slug. Eliminates "Googlecale…"
    /// truncation by giving the layout real word boundaries to wrap on.
    static func displayName(slug: String, catalogName: String) -> String {
        // If the catalog already returned a multi-word name, trust it.
        if catalogName.contains(" ") { return catalogName }
        if let override = nameOverrides[slug.lowercased()] { return override }
        // Last resort: split on common word boundaries hidden in the
        // slug (underscores, hyphens) and Title Case each piece.
        let pieces = slug
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return pieces.joined(separator: " ")
    }

    /// 2-letter monogram. Strategy in priority order:
    ///   1. Multi-word names → first letter of first two words
    ///      ("Google Calendar" → "GC", "Apple Music" → "AM").
    ///   2. CamelCase / PascalCase split → first letter of each
    ///      casing-segment ("GitHub" → "GH", "GitLab" → "GL",
    ///      "HubSpot" → "HS", "PagerDuty" → "PD").
    ///   3. Otherwise first two letters ("Gmail" → "GM",
    ///      "Slack" → "SL", "Notion" → "NO").
    static func monogram(slug: String, catalogName: String) -> String {
        let name = displayName(slug: slug, catalogName: catalogName)
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return (words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        // CamelCase split: scan for an interior capital letter and use
        // the first two upper-case glyphs as the monogram. Skip the
        // first char itself (which is always capital).
        if name.count >= 2 {
            let chars = Array(name)
            let firstUpper = chars[0]
            // Find the next uppercase character after position 0.
            if let i = (1..<chars.count).first(where: { chars[$0].isUppercase }) {
                return String([firstUpper, chars[i]]).uppercased()
            }
        }
        return name.prefix(2).uppercased()
    }

    /// Slugs we've pre-fetched the SVG logo for, converted to PDF, and
    /// bundled into Assets.xcassets/Composio/<slug>.imageset/. This is
    /// the *real* icon path — these render as the actual brand logos,
    /// crisp at any tile size because they're vector PDFs.
    ///
    /// Why bundled instead of fetched at runtime: Composio's CDN at
    /// logos.composio.dev only serves image/svg+xml. macOS's NSImage
    /// (and therefore SwiftUI's AsyncImage) doesn't decode SVG natively
    /// — every AsyncImage attempt falls through to the failure case
    /// without rendering. Pre-converting to PDF (via rsvg-convert at
    /// build time, see bin/refresh-composio-icons) sidesteps the decode
    /// limitation entirely and removes the network dependency for the
    /// 20 most-likely-to-be-used services.
    ///
    /// To add a new slug: append it here AND run the refresh script to
    /// pull + convert the SVG → PDF into Assets.xcassets/Composio/.
    static let bundledSlugs: Set<String> = [
        "gmail", "googlecalendar", "googledrive", "slack", "notion",
        "linear", "github", "asana", "gitlab", "discord", "zoom",
        "dropbox", "jira", "hubspot", "trello", "stripe", "twilio",
        "salesforce", "googlesheets", "googledocs",
    ]

    /// SwiftUI Image for the bundled brand logo, or nil if we haven't
    /// shipped one for this slug. Asset names live under the "Composio"
    /// namespace (Assets.xcassets/Composio/<slug>.imageset/).
    static func bundledLogo(for slug: String) -> Image? {
        guard bundledSlugs.contains(slug.lowercased()) else { return nil }
        return Image("Composio/\(slug.lowercased())")
    }

    /// Hand-curated SF Symbol fallback for services we haven't bundled
    /// a real logo for. Renders in the per-service palette color so
    /// the tile still reads as branded. Returns nil for unknown slugs
    /// → caller falls back to monogram.
    static func sfSymbol(for slug: String) -> String? {
        switch slug.lowercased() {
        case "gmail":          return "envelope.fill"
        case "googlecalendar": return "calendar"
        case "googledrive":    return "folder.fill"
        case "googledocs":     return "doc.text.fill"
        case "googlesheets":   return "tablecells.fill"
        case "slack":          return "number.circle.fill"
        case "notion":         return "book.closed.fill"
        case "linear":         return "chart.line.uptrend.xyaxis"
        case "github":         return "chevron.left.forwardslash.chevron.right"
        case "gitlab":         return "chevron.left.forwardslash.chevron.right"
        case "asana":          return "checkmark.circle.fill"
        case "trello":         return "rectangle.stack.fill"
        case "jira":           return "ladybug.fill"
        case "discord":        return "bubble.left.and.bubble.right.fill"
        case "zoom":           return "video.fill"
        case "dropbox":        return "shippingbox.fill"
        case "salesforce":     return "cloud.fill"
        case "hubspot":        return "person.2.fill"
        case "stripe":         return "creditcard.fill"
        case "twilio":         return "phone.fill"
        default:               return nil
        }
    }

    /// Deterministic color from the palette based on slug hash. Same
    /// slug always returns the same color across launches — important
    /// so users build visual recognition over time.
    static func color(for slug: String) -> Color {
        // Stable across launches: simple djb2-style hash on the lowered
        // slug bytes. Swift's `hashValue` is randomized per-launch so
        // it can't be used for a stable mapping.
        var h: UInt32 = 5381
        for byte in slug.lowercased().utf8 {
            h = (h &* 33) &+ UInt32(byte)
        }
        return palette[Int(h % UInt32(palette.count))]
    }
}

// MARK: - Featured tile

private struct FeaturedTile: View {
    let app: ComposioApp
    let size: CGFloat
    let isConnected: Bool
    let isConnecting: Bool
    let onTap: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tileFill)
                        .frame(width: size, height: size)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(borderColor, lineWidth: 0.75),
                        )

                    iconView()
                        .frame(width: size * 0.62, height: size * 0.62)

                    if isConnecting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(KloColors.olive)
                    }
                }
                .modifier(KloFireGlow(active: isConnected, radius: 8))

                Text(displayName)
                    .font(.kloCaption)
                    .foregroundStyle(isConnected ? KloColors.cream : KloColors.fg80)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: size + 12, height: 28, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isConnected ? "Disconnect \(displayName)" : "Connect \(displayName)")
    }

    private var displayName: String {
        BrandStyle.displayName(slug: app.slug, catalogName: app.name)
    }

    private var tileFill: Color {
        // The per-service color is the dominant visual differentiator
        // when icons fail to load — and they fail often. Hover lifts
        // the saturation slightly so the tile reads as live.
        let base = BrandStyle.color(for: app.slug)
        if isHovering { return base.opacity(0.28) }
        return base.opacity(0.18)
    }

    private var borderColor: Color {
        if isConnected { return KloColors.olive.opacity(0.55) }
        if isHovering { return BrandStyle.color(for: app.slug).opacity(0.55) }
        return KloColors.border
    }

    @ViewBuilder
    private func iconView() -> some View {
        // Priority order:
        //   1. Bundled brand logo (real SVG-converted-to-PDF, ships
        //      with the app, always renders crisp at any tile size).
        //   2. AsyncImage routed through the weserv proxy — Composio
        //      serves only image/svg+xml which NSImage doesn't decode,
        //      so we wrap the URL to get a rasterized PNG back.
        //   3. SF Symbol (curated for slugs without a bundled logo).
        //   4. 2-letter monogram.
        if let logo = BrandStyle.bundledLogo(for: app.slug) {
            logo
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let url = ConnectionsView.rasterIconURL(for: app.iconURL, size: 128) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fit)
                default:
                    iconFallback
                }
            }
        } else {
            iconFallback
        }
    }

    @ViewBuilder
    private var iconFallback: some View {
        if let symbol = BrandStyle.sfSymbol(for: app.slug) {
            Image(systemName: symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(BrandStyle.color(for: app.slug))
        } else {
            monogram
        }
    }

    private var monogram: some View {
        Text(BrandStyle.monogram(slug: app.slug, catalogName: app.name))
            .font(.system(size: size * 0.30, weight: .semibold, design: .rounded))
            .foregroundStyle(BrandStyle.color(for: app.slug))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Compact tile (all-apps grid)

private struct CompactTile: View {
    let app: ComposioApp
    let size: CGFloat
    let isConnected: Bool
    let isConnecting: Bool
    let onTap: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tileFill)
                    .frame(width: size, height: size)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(borderColor, lineWidth: 0.6),
                    )

                iconView()
                    .frame(width: size * 0.62, height: size * 0.62)

                if isConnecting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(KloColors.olive)
                }
            }
            .modifier(KloFireGlow(active: isConnected, radius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tooltipText)
    }

    private var displayName: String {
        BrandStyle.displayName(slug: app.slug, catalogName: app.name)
    }

    private var tooltipText: String {
        if isConnecting { return "Connecting \(displayName)…" }
        return isConnected ? "Disconnect \(displayName)" : "Connect \(displayName)"
    }

    private var tileFill: Color {
        let base = BrandStyle.color(for: app.slug)
        if isHovering { return base.opacity(0.28) }
        return base.opacity(0.18)
    }

    private var borderColor: Color {
        if isConnected { return KloColors.olive.opacity(0.55) }
        if isHovering { return BrandStyle.color(for: app.slug).opacity(0.55) }
        return KloColors.border
    }

    @ViewBuilder
    private func iconView() -> some View {
        // Same SVG-via-weserv routing as FeaturedTile — Composio's
        // logo CDN only serves image/svg+xml, which NSImage can't
        // decode. The proxy rasterizes to a small PNG that AsyncImage
        // handles natively.
        if let url = ConnectionsView.rasterIconURL(for: app.iconURL, size: 96) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fit)
                default:
                    iconFallback
                }
            }
        } else {
            iconFallback
        }
    }

    @ViewBuilder
    private var iconFallback: some View {
        if let symbol = BrandStyle.sfSymbol(for: app.slug) {
            Image(systemName: symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(BrandStyle.color(for: app.slug))
        } else {
            monogram
        }
    }

    private var monogram: some View {
        Text(BrandStyle.monogram(slug: app.slug, catalogName: app.name))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(BrandStyle.color(for: app.slug))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Esc handler

/// Tiny NSView wrapper that observes local keyDown events while this
/// view is in the hierarchy and calls `onEscape` when the user hits
/// the Escape key. Lives at the bottom of the SwiftUI tree (.background)
/// so it doesn't interfere with TextField focus / first responder.
private struct EscapeKeyCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = EscapeMonitorView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? EscapeMonitorView)?.onEscape = onEscape
    }

    private final class EscapeMonitorView: NSView {
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
                    guard ev.keyCode == 53 else { return ev }  // 53 = Escape
                    self?.onEscape?()
                    return nil
                }
            } else if window == nil, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
