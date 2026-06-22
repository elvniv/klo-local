import SwiftUI
import AppKit

/// "Connected Apps" section inside Settings → Account. Lists Composio-
/// backed integrations the user has connected, plus a featured-then-
/// expandable browser for the full 300+ catalog.
///
/// State comes from `AccountManager.connectedToolkits` (populated by
/// /auth/me on every refresh) and the catalog fetch is a one-shot per
/// view appear. Connect / Disconnect flow lives on AccountManager —
/// this view is purely presentation + dispatch.
struct IntegrationsView: View {
    @ObservedObject var account: AccountManager

    /// Featured tiles shown up-front. Curated for v0 — the user can
    /// reach everything via the "Browse all" expander but these are
    /// the services we expect 80%+ of users to want.
    // Slugs must match Composio's v3 catalog exactly (case-sensitive).
    // Verified 2026-05-28: gcalendar → googlecalendar, drive → googledrive.
    private static let featured: [String] = [
        "gmail", "googlecalendar", "slack", "notion",
        "linear", "github", "asana", "googledrive",
    ]

    @State private var catalog: [ComposioApp] = []
    @State private var loadError: String? = nil
    @State private var loadingCatalog: Bool = false
    @State private var showingBrowseAll: Bool = false

    // Per-toolkit account state for the multi-account expansion. Lazy:
    // we only fetch for toolkits the user has actually connected, the
    // first time we render their tile in connected state. Invalidated
    // when a connect / disconnect lifecycle finishes (see .onChange of
    // connectingToolkit below) so "+ Add another account" reflects
    // the fresh list without a full reload of Settings.
    @State private var connections: [String: [ComposioConnection]] = [:]
    @State private var loadingConnections: Set<String> = []
    @State private var connectionErrors: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("connected apps")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(KloColors.fg60)
                .textCase(.uppercase)

            // Featured tiles. Renders even if catalog hasn't loaded yet —
            // featured slugs are well-known, names are best-effort from
            // the catalog map (or the slug itself capitalized as a
            // fallback so the view doesn't show empty rows).
            VStack(spacing: 8) {
                ForEach(featuredApps, id: \.slug) { app in
                    appRow(app)
                }
            }

            // Browse-all expander. Lazy: we don't render the full 300+
            // list unless the user actually opens it.
            if !catalog.isEmpty {
                DisclosureGroup(isExpanded: $showingBrowseAll) {
                    VStack(spacing: 6) {
                        ForEach(nonFeaturedApps, id: \.slug) { app in
                            appRow(app, compact: true)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Browse all \(catalog.count) services")
                        .font(.kloCaption)
                        .foregroundStyle(KloColors.fg60)
                }
                .tint(KloColors.fg60)
            }

            if let err = loadError {
                Text(err)
                    .font(.kloCaption)
                    .foregroundStyle(KloColors.error)
            }
        }
        .padding(.top, 8)
        .task { await loadCatalogIfNeeded() }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func appRow(_ app: ComposioApp, compact: Bool = false) -> some View {
        let isConnected = account.connectedToolkits.contains(app.slug)
        let isConnecting = account.connectingToolkit == app.slug
        let iconSize: CGFloat = compact ? 18 : 24
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // Icon — small square. AsyncImage so we don't block on
                // icon fetches; a placeholder fills in immediately.
                iconView(for: app)
                    .frame(width: iconSize, height: iconSize)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(compact ? .kloCaption : .kloBody)
                        .foregroundStyle(KloColors.fg)
                    if !compact, !app.description.isEmpty {
                        Text(app.description)
                            .font(.kloCaption)
                            .foregroundStyle(KloColors.fg60)
                            .lineLimit(1)
                    }
                }
                Spacer()
                actionButton(for: app, isConnected: isConnected, isConnecting: isConnecting)
            }
            // Inline accounts panel — only renders for connected
            // toolkits. Indented under the toolkit name so the eye
            // groups the accounts with their parent service.
            if isConnected {
                accountsPanel(for: app)
                    .padding(.leading, iconSize + 12)
            }
        }
        .padding(.vertical, compact ? 4 : 6)
        .task(id: isConnected) {
            // Fetch when this tile first renders in connected state,
            // and again whenever the connected/disconnected toggle
            // flips. Avoids hitting list_connections for toolkits
            // the user hasn't touched.
            if isConnected {
                await loadConnectionsIfNeeded(slug: app.slug)
            } else {
                connections.removeValue(forKey: app.slug)
                connectionErrors.removeValue(forKey: app.slug)
            }
        }
        .onChange(of: account.connectingToolkit) { oldValue, newValue in
            // After a connect cycle for this slug clears (success or
            // failure), invalidate the cached account list so the
            // freshly added account shows up. This is the "+ Add
            // another account" path — connectedToolkits doesn't flip
            // because the slug was already there, so .task(id:) won't
            // re-fire on its own.
            if oldValue == app.slug && newValue == nil && isConnected {
                connections.removeValue(forKey: app.slug)
                Task { await loadConnectionsIfNeeded(slug: app.slug) }
            }
        }
    }

    @ViewBuilder
    private func accountsPanel(for app: ComposioApp) -> some View {
        let list = connections[app.slug] ?? []
        let isLoading = loadingConnections.contains(app.slug)
        let err = connectionErrors[app.slug]
        VStack(alignment: .leading, spacing: 4) {
            if isLoading && list.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(KloColors.olive)
                    Text("loading accounts…")
                        .font(.kloCaption)
                        .foregroundStyle(KloColors.fg45)
                }
            } else if let err = err {
                Text(err)
                    .font(.kloCaption)
                    .foregroundStyle(KloColors.error)
            } else {
                ForEach(list) { conn in
                    accountRow(toolkit: app.slug, connection: conn)
                }
                addAnotherButton(toolkit: app.slug)
            }
            // Surface any error from a recent startComposioConnect
            // attempt against THIS tile. AccountManager sets
            // lastSignInError when /integrations/composio/connect
            // throws (network, 401, 503, malformed redirect URL) and
            // clears connectingToolkit. Without rendering it here the
            // user sees the spinner blink and disappear with no
            // feedback — which reads as "the button did nothing."
            //
            // Gated on connectingToolkit == nil (so it doesn't flash
            // mid-flight) and on the slug being this app's (so the
            // error doesn't leak across tiles). The error string is
            // shared across surfaces; the gating is the best signal
            // we have that it belongs to a recent connect for this
            // toolkit specifically.
            if let err = account.lastSignInError,
               account.connectingToolkit == nil,
               account.lastConnectAttemptToolkit == app.slug {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(KloColors.error)
                    Text(err)
                        .font(.kloCaption)
                        .foregroundStyle(KloColors.error)
                        .lineLimit(2)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func accountRow(toolkit: String, connection: ComposioConnection) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(KloColors.olive)
                .frame(width: 4, height: 4)
            Text(connection.label)
                .font(.kloCaption)
                .foregroundStyle(KloColors.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Disconnect") {
                // Optimistic local removal so the row disappears
                // immediately — the backend call + /auth/me refresh
                // catches up within ~250ms. If the backend rejects,
                // the next refresh restores the row.
                connections[toolkit] = (connections[toolkit] ?? [])
                    .filter { $0.id != connection.id }
                account.disconnectComposioConnection(
                    toolkit: toolkit,
                    connectionId: connection.id,
                )
            }
            .buttonStyle(.plain)
            .font(.kloCaption)
            .foregroundStyle(KloColors.fg45)
        }
    }

    @ViewBuilder
    private func addAnotherButton(toolkit: String) -> some View {
        Button {
            // NSLog so "did my click even register?" is answerable from
            // Console.app without rebuilding. If this line appears in
            // the log but the browser never opens, the failure is in
            // startComposioConnect / the backend; if it doesn't appear
            // at all, the button isn't receiving the click (hit-test
            // or modal swallowing the event).
            NSLog("KLO Integrations: Add-another-account tapped for \(toolkit)")
            account.startComposioConnect(toolkit: toolkit)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Text("Add another account")
                    .font(.kloCaption)
            }
            .foregroundStyle(KloColors.fg60)
            // contentShape extends the hit-test area to the entire
            // padded frame. Without this, .buttonStyle(.plain) on
            // macOS makes only the glyph pixels of the icon + text
            // tappable — clicks in the gap between or in the
            // surrounding padding silently drop, which feels like
            // "the button does nothing." This was the bug.
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    @MainActor
    private func loadConnectionsIfNeeded(slug: String) async {
        if connections[slug] != nil { return }
        if loadingConnections.contains(slug) { return }
        loadingConnections.insert(slug)
        defer { loadingConnections.remove(slug) }
        do {
            let list = try await account.fetchConnections(toolkit: slug)
            connections[slug] = list
            connectionErrors.removeValue(forKey: slug)
        } catch let err as ComposioError {
            connectionErrors[slug] = err.errorDescription ?? "Couldn't load accounts."
        } catch {
            connectionErrors[slug] = "Couldn't load accounts."
        }
    }

    @ViewBuilder
    private func iconView(for app: ComposioApp) -> some View {
        if let url = app.iconURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fit)
                default:
                    placeholderIcon(slug: app.slug)
                }
            }
        } else {
            placeholderIcon(slug: app.slug)
        }
    }

    private func placeholderIcon(slug: String) -> some View {
        // Two-letter monogram in olive — readable on any background and
        // consistent with klo's pip palette.
        RoundedRectangle(cornerRadius: 4)
            .fill(KloColors.olive.opacity(0.18))
            .overlay(
                Text(String(slug.prefix(2)).uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(KloColors.olive),
            )
    }

    @ViewBuilder
    private func actionButton(for app: ComposioApp, isConnected: Bool, isConnecting: Bool) -> some View {
        if isConnecting {
            HStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(KloColors.olive)
                Button("Cancel") {
                    account.cancelToolkitConnect(app.slug)
                }
                .buttonStyle(.plain)
                .font(.kloCaption)
                .foregroundStyle(KloColors.fg60)
            }
        } else if isConnected {
            // Olive pip + count summary. Per-account "Disconnect" lives
            // in the accountsPanel below so the user can drop one of
            // several Gmails without nuking the rest; a top-level
            // "Disconnect all" would compete with that affordance and
            // is a rare-enough need that we'd rather make people
            // remove accounts one by one (clearer intent, lower risk
            // of accidental fan-out).
            HStack(spacing: 8) {
                Circle()
                    .fill(KloColors.olive)
                    .frame(width: 6, height: 6)
                let count = connections[app.slug]?.count ?? 0
                Text(count > 1 ? "\(count) connected" : "Connected")
                    .font(.kloCaption)
                    .foregroundStyle(KloColors.fg60)
            }
        } else {
            Button("Connect") {
                account.startComposioConnect(toolkit: app.slug)
            }
            .buttonStyle(.kloGhost)
        }
    }

    // MARK: - Catalog helpers

    private var featuredApps: [ComposioApp] {
        Self.featured.map { slug in
            // Prefer the catalog's metadata if loaded; synthesize a
            // minimal ComposioApp from the slug otherwise so featured
            // tiles render immediately on first paint.
            if let hit = catalog.first(where: { $0.slug == slug }) { return hit }
            return ComposioApp(
                slug: slug,
                name: slug.replacingOccurrences(of: "_", with: " ").capitalized,
                description: "",
                iconURL: nil,
            )
        }
    }

    private var nonFeaturedApps: [ComposioApp] {
        let featuredSet = Set(Self.featured)
        return catalog.filter { !featuredSet.contains($0.slug) }
    }

    @MainActor
    private func loadCatalogIfNeeded() async {
        guard catalog.isEmpty, !loadingCatalog else { return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            let apps = try await account.fetchComposioCatalog()
            self.catalog = apps
            self.loadError = nil
        } catch let err as ComposioError {
            // notConfigured + subscriptionRequired are expected states
            // we render with copy rather than a red error string.
            switch err {
            case .notConfigured:
                self.loadError = "Composio isn't enabled on this server yet."
            case .subscriptionRequired:
                self.loadError = "Subscribe to klo Pro to connect apps."
            default:
                self.loadError = err.errorDescription
            }
        } catch {
            self.loadError = "Couldn't load the integrations catalog."
        }
    }
}
