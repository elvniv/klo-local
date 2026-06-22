import SwiftUI

/// One proactive pill in the row that sits beneath the notch's chat
/// input. Three kinds map to where the suggestion came from:
///
///   - `.calendar`  – connect-CTA pill for Google Calendar (Composio
///                    OAuth). Hidden once any googlecalendar account
///                    is connected — the googlecalendar connector pill
///                    ("today's events") takes over from there.
///   - `.screen`    – live signal pulled from the frontmost window
///                    (browser page title, app-specific verbs).
///   - `.connector` – a curated Composio toolkit starter prompt
///                    (gmail, slack, notion …), ranked by what the
///                    user has actually connected.
///
/// Pills are immutable snapshots. They're computed on every notch
/// opening and handed to the view layer with the exact prompt to drop
/// into the input on tap — so the view stays declarative.
struct ProactiveSignal: Identifiable, Equatable {
    let id: UUID
    let kind: Kind

    /// The short, lowercase, verb-led text rendered inside the pill.
    /// Connector pills follow iOS PromptSuggestions verbatim ("search
    /// Gmail", "today's events"); live pills use the same vocabulary
    /// scoped to actual context ("brief sarah 1:1", "summarize this
    /// page").
    let label: String

    /// The prompt that drops into the input on tap. Connector pills
    /// always begin with `/<slug> …` so klo's slash-routing scopes the
    /// run; live pills are plain prose since they're already specific.
    let prompt: String

    /// Visual mark on the left of the pill. Connector pills use the
    /// Composio brand glyph (or a monogrammed fallback) — same chip
    /// the user already sees in `ConnectionsView`. Live pills use SF
    /// Symbols colored by accent so they read as "klo's own signal"
    /// rather than a third-party brand.
    let icon: Icon

    /// Tint for the icon (and the pill border on hover). Connector
    /// pills are `.brand` so the icon stays full-color; live pills
    /// pick from olive (calendar), copper (acting on something of
    /// yours), teal (neutral / waiting).
    let accent: Accent

    enum Kind {
        case calendar
        case screen
        case connector
        // klo 2.1 Track A: highest-confidence pending routine
        // suggestion from the detector. Tap → opens proposal card.
        case routineSuggestion
        // klo 2.1 Track A: scheduled run currently executing in the
        // cloud. Always at the leading edge when present. Tap → opens
        // cancel-while-running inline panel.
        case runningSchedule
        // klo 2.1 Track B: day-1 discovery hint shown to brand-new
        // users with no schedules or suggestions yet. Tap drops an
        // example prompt into the input.
        case routineTip
    }

    enum Icon: Equatable {
        case sfSymbol(String)
        /// Connector pill. Carries the toolkit slug so the view layer
        /// can ask `BrandStyle` for the right logo / monogram /
        /// brand color at render time.
        case composio(slug: String)
    }

    enum Accent: Equatable {
        case olive, copper, teal, brand
    }
}

extension ProactiveSignal {
    /// Sentinel prompt the host watches for to route into the
    /// "request Calendar permission" flow instead of submitting to
    /// the agent.
    static let connectCalendarPrompt = "__klo.connect_calendar__"
    /// 2.1 Track A: tap-target sentinels for the new pill kinds.
    /// The host watches for these prefixes and routes accordingly
    /// instead of dropping them into the text input.
    static let suggestionPromptPrefix = "__klo.suggestion__:"   // suffix: suggestion id
    static let runningPillPrefix      = "__klo.running__:"      // suffix: task id
}
