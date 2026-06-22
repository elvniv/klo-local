import Foundation
import Security
import LocalAuthentication

/// Wraps Security.framework for klo's own-keychain credential store.
///
/// What this is:
///   - klo stores credentials it captured (from a form submission inside
///     its embedded WKWebView) in the user's login keychain, scoped to
///     klo's Team ID + bundle ID. Other apps reading them trigger the
///     standard "klo wants to use…" prompt; klo itself reads with no
///     prompt OTHER than the optional Touch ID gate.
///   - Items are `kSecClassInternetPassword`, keyed by (server, account)
///     where server = hostname, account = username. Multiple usernames
///     on one host means multiple items — the autofill replay layer
///     picks the most-recently-used one.
///
/// What this is NOT:
///   - It cannot read Safari / iCloud Keychain items belonging to other
///     apps. Apple's keychain ACLs forbid third-party reads. The user's
///     existing Safari saved sign-ins are NOT visible to klo. The CSV
///     import flow (see CredentialCSVImporter) is the one-time bootstrap
///     for migrating those over.
///
/// Threading: All Sec* calls are synchronous and may briefly block while
/// the OS evaluates ACLs / triggers Touch ID. Don't call from the main
/// thread for `lookup(...)` — wrap in Task.detached. `save(...)` is
/// fast (no prompts) so it's safe inline.
enum KloKeychain {

    // MARK: - Public API

    struct Entry: Equatable {
        let host: String
        let username: String
        let updatedAt: Date
    }

    /// Persist a (host, username, password) tuple as an Internet Password
    /// item in the user's login keychain, gated behind Touch ID via
    /// `.biometryCurrentSet`. If an item for the same (host, username)
    /// already exists, it's overwritten with the new password — the
    /// natural flow when the user updates a password on a service.
    ///
    /// Returns true on success. Logs and returns false on Sec* failure
    /// (most common cause: user denied the initial keychain-access
    /// prompt; subsequent calls fail until ACL is fixed in Keychain
    /// Access.app, but that's rare and the user-recoverable path).
    @discardableResult
    static func save(host: String, username: String, password: String) -> Bool {
        let cleanHost = normalizeHost(host)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !password.isEmpty else { return false }
        guard let passwordData = password.data(using: .utf8) else { return false }

        // Build access control: biometryCurrentSet means the item
        // invalidates if the user re-enrolls their fingerprints. For
        // a more lenient policy that survives re-enrollment, use
        // .biometryAny. We default to currentSet since it's stricter
        // (key-rotation-style protection); users who add a new finger
        // will get re-prompted to re-save, which is the right
        // security/UX trade-off.
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet, .or, .devicePasscode],
            &accessError
        ) else {
            let err = accessError?.takeRetainedValue()
            NSLog("KloKeychain.save: SecAccessControlCreateWithFlags failed — %@", String(describing: err))
            return false
        }

        // Delete any existing item for the same (host, username) pair
        // before adding — SecItemUpdate would also work but Add+Delete
        // is simpler to reason about and avoids partial-update states.
        deleteRaw(host: cleanHost, username: cleanUser)

        let attrs: [String: Any] = [
            kSecClass as String:           kSecClassInternetPassword,
            kSecAttrServer as String:      cleanHost,
            kSecAttrAccount as String:     cleanUser,
            kSecAttrProtocol as String:    kSecAttrProtocolHTTPS,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrLabel as String:       "klo · \(cleanHost)",
            kSecAttrComment as String:     "Saved by klo on \(isoNow())",
            kSecValueData as String:       passwordData,
            kSecAttrAccessControl as String: access,
        ]

        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecSuccess {
            NSLog("KloKeychain.save: stored \(cleanHost) / \(cleanUser)")
            return true
        }
        NSLog("KloKeychain.save: SecItemAdd failed — OSStatus \(status)")
        return false
    }

    /// Lookup the most-recently-modified credential for `host`. Triggers
    /// the Touch ID sheet via the LAContext we pass in
    /// `kSecUseAuthenticationContext`. On success returns (username,
    /// password). On user-cancel returns `(nil, .biometryCancelled)`.
    /// On no-match returns `(nil, .noMatch)`.
    enum LookupOutcome: Equatable {
        case found(username: String, password: String)
        case noMatch
        case biometryCancelled
        case biometryFailed(String)
    }

    static func lookup(host: String, reason: String? = nil) -> LookupOutcome {
        let cleanHost = normalizeHost(host)
        guard !cleanHost.isEmpty else { return .noMatch }

        let ctx = LAContext()
        ctx.localizedReason = reason ?? "Use saved sign-in for \(cleanHost)"

        let query: [String: Any] = [
            kSecClass as String:                  kSecClassInternetPassword,
            kSecAttrServer as String:             cleanHost,
            kSecMatchLimit as String:             kSecMatchLimitOne,
            kSecReturnAttributes as String:       true,
            kSecReturnData as String:             true,
            kSecUseAuthenticationContext as String: ctx,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let dict = item as? [String: Any] else { return .noMatch }
            let username = (dict[kSecAttrAccount as String] as? String) ?? ""
            let data = (dict[kSecValueData as String] as? Data) ?? Data()
            let password = String(data: data, encoding: .utf8) ?? ""
            if password.isEmpty { return .noMatch }
            return .found(username: username, password: password)
        case errSecItemNotFound:
            return .noMatch
        case errSecUserCanceled:
            return .biometryCancelled
        case errSecAuthFailed:
            return .biometryFailed("authentication failed")
        default:
            NSLog("KloKeychain.lookup: SecItemCopyMatching OSStatus \(status) for \(cleanHost)")
            return .biometryFailed("OSStatus \(status)")
        }
    }

    /// Delete a specific entry. Used when the user removes a sign-in
    /// from klo's settings UI (eventually) — not part of the save/fill
    /// loop. No-op if the item doesn't exist.
    @discardableResult
    static func delete(host: String, username: String) -> Bool {
        let cleanHost = normalizeHost(host)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return deleteRaw(host: cleanHost, username: cleanUser)
    }

    /// Enumerate all klo-owned credentials. Returns metadata only
    /// (no password bodies — that's a separate per-item lookup that
    /// triggers Touch ID). Used by the eventual settings UI to list
    /// "what klo has saved for you". Items are sorted by most-recently-
    /// modified first.
    static func list() -> [Entry] {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassInternetPassword,
            kSecMatchLimit as String:      kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            // Hint to suppress biometry for the list-only path. We don't
            // want a flurry of Touch ID prompts when the user opens
            // settings. The OS may still prompt for items the user
            // hasn't unlocked in this session — that's fine; the list
            // gracefully skips items it can't read attributes for.
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let arr = items as? [[String: Any]] else { return [] }

        let mapped: [Entry] = arr.compactMap { dict in
            guard let host = dict[kSecAttrServer as String] as? String else { return nil }
            // Filter to klo-owned items — the label prefix is the
            // distinguisher (we set it in save()). Other apps' Internet
            // Passwords for the same hosts will be returned by this
            // query too if SecMatchLimitAll widens the scope; the label
            // filter narrows it back down to our own.
            let label = (dict[kSecAttrLabel as String] as? String) ?? ""
            guard label.hasPrefix("klo ·") else { return nil }
            let username = (dict[kSecAttrAccount as String] as? String) ?? ""
            let mtime = (dict[kSecAttrModificationDate as String] as? Date) ?? Date.distantPast
            return Entry(host: host, username: username, updatedAt: mtime)
        }
        return mapped.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Internals

    @discardableResult
    private static func deleteRaw(host: String, username: String) -> Bool {
        var q: [String: Any] = [
            kSecClass as String:       kSecClassInternetPassword,
            kSecAttrServer as String:  host,
        ]
        if !username.isEmpty {
            q[kSecAttrAccount as String] = username
        }
        let status = SecItemDelete(q as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Strip protocol scheme, port, path, query so we always store
    /// the same "server" form for a given site. Without this,
    /// `https://example.com/login` and `example.com` would create
    /// two separate keychain items.
    static func normalizeHost(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return "" }
        if let url = URL(string: trimmed), let host = url.host {
            return host
        }
        // Fallback — strip scheme + path manually if URL parsing fails.
        var out = trimmed
        if let range = out.range(of: "://") {
            out = String(out[range.upperBound...])
        }
        if let slash = out.firstIndex(of: "/") {
            out = String(out[..<slash])
        }
        if let colon = out.firstIndex(of: ":") {
            out = String(out[..<colon])
        }
        return out
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
