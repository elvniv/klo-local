import Foundation
import SwiftUI

/// Durable, threaded record of every notch conversation. Replaces the
/// old RunHistoryStore's flat entry list with first-class conversations
/// so the user can resume any prior thread (history overlay, Settings
/// recent list) instead of just re-reading prompts.
///
/// Persistence model: one JSON file (conversations.json in Application
/// Support) holding a root object { active: UUID?, conversations: [] }.
/// The `active` pointer is what appendToActive targets; clearing it via
/// startNew() is all "archiving" means — the conversations array IS the
/// archive, newest-updated first via `list`.
///
/// Caps: 50 conversations (oldest-updated dropped first) and 200
/// messages per conversation, so the file stays small enough to write
/// atomically on every turn without measurable cost.
@MainActor
final class ConversationStore: ObservableObject {

    static let shared = ConversationStore()

    /// One turn. Same shape the old RunHistoryStore used so the
    /// migration is a straight re-grouping, no field surgery.
    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let role: String          // "user" | "assistant"
        let content: String
        let scopedService: String?
        let date: Date
    }

    struct Conversation: Codable, Identifiable, Equatable {
        let id: UUID
        var title: String
        let createdAt: Date
        var updatedAt: Date
        var messages: [Entry]

        /// Last turn of either role — drives the one-line preview in
        /// the history overlay and the Settings recent list.
        var lastMessage: Entry? { messages.last }
    }

    /// On-disk root. `active` survives restarts so a same-session
    /// follow-up after relaunch lands in the right thread (subject to
    /// KLOState's 2-hour staleness check).
    private struct Root: Codable {
        var active: UUID?
        var conversations: [Conversation]
    }

    static let maxConversations = 50
    static let maxMessagesPerConversation = 200

    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var activeConversationID: UUID?

    private let fileURL: URL
    private let legacyFileURL: URL

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("klo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("conversations.json")
        legacyFileURL = dir.appendingPathComponent("run-history.json")
        load()
    }

    // MARK: - Public API

    /// Conversations newest-updated first — the order every list UI
    /// (history overlay, Settings) wants.
    var list: [Conversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeConversation: Conversation? {
        guard let id = activeConversationID else { return nil }
        return conversations.first { $0.id == id }
    }

    /// Append a turn to the active conversation, creating one lazily
    /// when there is no active pointer (first turn after launch, after
    /// startNew(), or after a delete of the active thread).
    func appendToActive(role: String, content: String, scopedService: String? = nil) {
        let entry = Entry(
            id: UUID(),
            role: role,
            content: content,
            scopedService: scopedService,
            date: Date()
        )
        if let id = activeConversationID,
           let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].messages.append(entry)
            // A dangling-seal assistant note can be the very first turn
            // routed into a lazily-created conversation (mirror-pickup
            // threads start assistant-side) — backfill the title from
            // the first user turn whenever one lands.
            if conversations[idx].title.isEmpty && role == "user" {
                conversations[idx].title = Self.makeTitle(content)
            }
            conversations[idx].updatedAt = entry.date
            trimMessages(at: idx)
        } else {
            let conv = Conversation(
                id: UUID(),
                title: role == "user" ? Self.makeTitle(content) : "",
                createdAt: entry.date,
                updatedAt: entry.date,
                messages: [entry]
            )
            conversations.append(conv)
            activeConversationID = conv.id
        }
        trimConversations()
        save()
    }

    /// Drop the active pointer. The current thread stays in
    /// `conversations` — that array is the archive — so nothing else
    /// needs to move.
    func startNew() {
        guard activeConversationID != nil else { return }
        activeConversationID = nil
        save()
    }

    /// Point the active pointer at a stored conversation and bump its
    /// recency so it sorts to the top of `list`. Returns the
    /// conversation so the caller (KLOState) can hydrate its live
    /// messages.
    func resume(id: UUID) -> Conversation? {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return nil }
        conversations[idx].updatedAt = Date()
        activeConversationID = id
        save()
        return conversations[idx]
    }

    func delete(id: UUID) {
        conversations.removeAll { $0.id == id }
        if activeConversationID == id {
            activeConversationID = nil
        }
        save()
    }

    func clear() {
        conversations.removeAll()
        activeConversationID = nil
        save()
    }

    // MARK: - Title

    /// First user message, trimmed, cut at ~60 chars on a word boundary
    /// so list rows never end mid-word.
    static func makeTitle(_ raw: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 60 else { return trimmed }
        let prefix = trimmed.prefix(60)
        // Only respect the word boundary when it doesn't gut the title —
        // a 58-char first word should still truncate mid-word rather
        // than collapse to almost nothing.
        if let lastSpace = prefix.lastIndex(of: " "),
           prefix.distance(from: prefix.startIndex, to: lastSpace) > 20 {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }

    // MARK: - Internals

    private func trimMessages(at idx: Int) {
        let overflow = conversations[idx].messages.count - Self.maxMessagesPerConversation
        if overflow > 0 {
            conversations[idx].messages.removeFirst(overflow)
        }
    }

    private func trimConversations() {
        guard conversations.count > Self.maxConversations else { return }
        // Drop oldest-updated first; never drop the active thread even
        // if it's somehow the stalest (resume() bumps updatedAt, so in
        // practice the active thread is always recent).
        let sortedByAge = conversations.sorted { $0.updatedAt < $1.updatedAt }
        var toDrop = conversations.count - Self.maxConversations
        for conv in sortedByAge where toDrop > 0 {
            if conv.id == activeConversationID { continue }
            conversations.removeAll { $0.id == conv.id }
            toDrop -= 1
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL) {
            do {
                let root = try decoder.decode(Root.self, from: data)
                conversations = root.conversations
                activeConversationID = root.active
            } catch {
                NSLog("KLO Conversations: failed to decode \(fileURL.lastPathComponent) — \(error.localizedDescription); starting fresh")
                conversations = []
                activeConversationID = nil
            }
            return
        }
        migrateFromLegacyHistory(decoder: decoder)
    }

    /// One-time migration from the flat run-history.json: split entries
    /// into conversations wherever the gap between consecutive turns
    /// exceeds 2 hours (same threshold KLOState uses for staleness, so
    /// the seams match the user's mental model of "that was a different
    /// session"). The legacy file is left in place — harmless, and a
    /// safety net if this build is rolled back.
    private func migrateFromLegacyHistory(decoder: JSONDecoder) {
        guard let data = try? Data(contentsOf: legacyFileURL),
              let entries = try? decoder.decode([Entry].self, from: data),
              !entries.isEmpty else { return }

        let gap: TimeInterval = 2 * 60 * 60
        var groups: [[Entry]] = []
        var current: [Entry] = []
        for entry in entries {
            if let last = current.last, entry.date.timeIntervalSince(last.date) > gap {
                groups.append(current)
                current = []
            }
            current.append(entry)
        }
        if !current.isEmpty { groups.append(current) }

        conversations = groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let firstUser = group.first { $0.role == "user" }
            return Conversation(
                id: UUID(),
                title: firstUser.map { Self.makeTitle($0.content) } ?? "",
                createdAt: first.date,
                updatedAt: last.date,
                messages: group
            )
        }
        // No active pointer after migration — the old store never
        // tracked one, and resuming a guessed thread silently would be
        // worse than starting clean.
        activeConversationID = nil
        trimConversations()
        save()
        NSLog("KLO Conversations: migrated \(entries.count) legacy entries into \(conversations.count) conversations")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(Root(active: activeConversationID, conversations: conversations))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("KLO Conversations: failed to save — \(error.localizedDescription)")
        }
    }
}
