import Foundation

/// klo-cloud /messages model + small GET helper for the notch's
/// cross-surface pickup affordance (hermes-five M1).
///
/// The Mac sidecar mirrors completed runs server-side via desktop_api,
/// so this client only READS the mirror stream for the notch UI.
/// The notch fires `MirrorClient.fetchRecent()` when the user opens
/// it via ⌘K and renders a small pickup card if any of those messages
/// are newer than the local in-memory transcript's session.

/// One row in public.messages. Mirror of `the hosted mirror message model`.
struct MirrorMessage: Codable, Identifiable, Equatable {
    let id: String
    let source: String              // 'mac' | 'ios' | 'extension' | 'voice' | 'scheduled'
    let source_session_id: String?
    let role: String                // 'user' | 'assistant'
    let content: String
    let scoped_service: String?
    let run_id: String?
    let created_at: String          // ISO8601
}

private struct ListMessagesEnvelope: Codable {
    let messages: [MirrorMessage]
}

enum MirrorClient {
    /// GET /messages?limit=N. Takes the AccountManager from the caller
    /// (notch view layer) so the call reuses its proactive-refresh +
    /// single-flight token logic for free.
    /// Silent failure → empty array; the pickup UI gracefully renders
    /// nothing when this returns an empty slice.
    @MainActor
    static func fetchRecent(using account: AccountManager, limit: Int = 10) async -> [MirrorMessage] {
        guard let token = await account.withFreshAccessToken() else {
            return []
        }
        guard var components = URLComponents(
            url: AccountManager.cloudBase.appendingPathComponent("messages"),
            resolvingAgainstBaseURL: false,
        ) else { return [] }
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components.url else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                NSLog("KLO Mirror: /messages HTTP %d",
                      (resp as? HTTPURLResponse)?.statusCode ?? -1)
                return []
            }
            let envelope = try JSONDecoder().decode(ListMessagesEnvelope.self, from: data)
            // Server returns most-recent first; that matches what the
            // pickup card wants to show.
            return envelope.messages
        } catch {
            NSLog("KLO Mirror: /messages error — %@", String(describing: error))
            return []
        }
    }
}
