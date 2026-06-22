import Foundation

/// Lightweight token store for klo's hosted-mode Supabase session.
///
/// Previously this was backed by the macOS Keychain. The keychain
/// trips a brutal UX failure during development (and on signed-build
/// updates): Debug rebuilds change the binary's cdhash each time, so
/// macOS doesn't recognize the new build as the same app that wrote
/// the keychain item — and it pops a login-password prompt every
/// launch:
///
///     "klo wants to use your confidential information stored in
///      com.klo.KLO in your keychain. Enter the login keychain password."
///
/// That prompt's anxiety vastly outweighs the benefit of OS-level
/// encryption-at-rest for a Supabase session token. The token rotates
/// every ~hour, can be revoked server-side at any time, and is
/// session-scoped — it isn't an API key or a credit card number.
///
/// So the storage moved to `UserDefaults` (plain-text under
/// `~/Library/Preferences/com.klo.KLO.plist`). The threat model
/// trade-off is explicit: anyone with file-system access to the
/// user's home directory could read the token — but they could also
/// attach a debugger, dump process memory, read the sidecar session
/// file, or scrape the URLSession requests. The keychain didn't add
/// meaningful security for this data; it just added a recurring
/// password prompt.
///
/// API surface kept identical (enum name, methods, errors) so call
/// sites in `AccountManager` don't need to change. Type name kept as
/// `KeychainStore` for the same reason — the implementation detail
/// is contained here.
///
/// NOTE on legacy items: any keychain entries created by previous
/// builds remain in the user's keychain, harmless and unread. We do
/// NOT call `SecItemDelete` to clean them up because the cleanup
/// itself can trigger the same prompt — which would defeat the
/// entire reason for this migration. They'll sit unused.
enum KeychainStore {

    /// Prefix applied to every UserDefaults key so we don't collide
    /// with other keys living under com.klo.KLO.
    private static let prefix = "klo.auth."

    /// Stable IDs for each thing we store. Centralized so call sites
    /// don't drift on spelling.
    enum Account {
        // Hosted-mode auth (Supabase session). The Mac app stores both
        // tokens; the access token is sent on every klo-cloud request,
        // the refresh token is used to swap for a fresh access token
        // when the current one expires (~1h ttl by default).
        static let supabaseAccessToken = "supabase_access_token"
        static let supabaseRefreshToken = "supabase_refresh_token"
    }

    /// Kept for API compatibility with the previous keychain-backed
    /// implementation. UserDefaults reads/writes don't actually fail
    /// in practice, so these cases never get thrown — but the type
    /// remains so callers like `try? KeychainStore.set(...)` keep
    /// compiling without changes.
    enum KeychainError: Error, CustomStringConvertible {
        case storeFailed(Int)
        case readFailed(Int)
        case deleteFailed(Int)
        case dataDecodingFailed

        var description: String {
            switch self {
            case .storeFailed(let s):  return "token store failed (status \(s))"
            case .readFailed(let s):   return "token read failed (status \(s))"
            case .deleteFailed(let s): return "token delete failed (status \(s))"
            case .dataDecodingFailed:  return "token data decoding failed"
            }
        }
    }

    static func set(_ value: String, account: String) throws {
        UserDefaults.standard.set(value, forKey: prefix + account)
    }

    static func get(account: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + account)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        UserDefaults.standard.removeObject(forKey: prefix + account)
        return true
    }
}
