import Foundation

/// One transient bubble of activity copy rendered above the working
/// fire. Owned by `KLOState.activityBubbles`. Identifiable so SwiftUI
/// can diff the stack and animate inserts/removes by id.
///
/// Bubbles are append-only from the state's perspective — the view
/// caps the visible stack at 3 and ages bubbles out by `createdAt`.
struct ActivityBubble: Identifiable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(text: String, createdAt: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.createdAt = createdAt
    }
}
