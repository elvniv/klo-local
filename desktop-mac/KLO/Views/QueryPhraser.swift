import Foundation

/// Pure function: user's submitted prompt → ONE starting bubble phrase.
///
/// This is the dopamine hit. The moment the user hits return, we want a
/// bubble to appear over the fire before any sidecar response has
/// landed. The phrase is chosen by sniffing the prompt text for intent
/// keywords — "open notes and write hello" → "opening it up" feels
/// instant + on-task; the alternative is a generic spinner for ~3s
/// until the agent's first tool call streams back.
///
/// Intent-matching is intentionally crude. We're not parsing meaning;
/// we're picking the LEAST WRONG opener for ~80% of common phrasings.
/// Falls back to a varied "on it" pool for unmatched prompts so the
/// experience doesn't feel canned.
enum QueryPhraser {

    /// Pick a single starting phrase for the prompt. Always returns a
    /// non-empty string — even if no keyword matches, we surface a
    /// reassurance ("on it", "let me see", etc.).
    static func startingPhrase(for query: String) -> String {
        // klo 2.1.1: routine previews enter .working with the query
        // "Preview: <routine name>". Detect that up front so the user
        // sees a preview-specific bubble instead of generic "on it"
        // copy — reinforces that they tapped a suggestion and klo
        // is showing them what it WOULD do, not running it for real.
        if query.hasPrefix("Preview: ") {
            return "previewing this for you"
        }
        let q = query.lowercased()

        // ─── Conversational shapes ──────────────────────────────────
        //
        // BEFORE we hit the action-verb pattern matching below, check
        // whether this is a SOCIAL message — a greeting, a thanks, a
        // single "wow", a "?". The old default pool slapped "on it" on
        // all of those, which read like a help-desk bot answering a
        // hello. Klo should match the user's register: a "hey" gets a
        // "hey", an "ok" gets a "yeah", a "thanks" gets an "anytime."
        //
        // Detection is EXACT-match on the trimmed, lowercased, end-
        // punctuation-stripped string. We do NOT match substrings
        // because "thanks for setting up the meeting" is a real task,
        // not a thank-you. If the user wraps their task in a greeting
        // ("hey, can you summarize this") the action-verb match below
        // still fires (".. summarize ..." → "looking it up") and the
        // greeting wrapper is harmless.
        let bare = q
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        if let social = _socialPhrase(bare: bare) {
            return social
        }

        // Order matters — earlier matches win when a prompt straddles
        // multiple buckets (e.g. "open notes and write hello" matches
        // both "open" and "write"). "Open" wins because it's the first
        // observable action; the write bubble will arrive on its own
        // from the agent's tool call.
        if _anyMatch(in: q, of: ["open ", "launch ", "start "]) {
            return _hashPick(q, ["opening it up", "opening that"])
        }
        if _anyMatch(in: q, of: ["play ", "put on ", "listen to ",
                                 "queue ", "shuffle "]) {
            return _hashPick(q, ["putting it on", "playing that for you"])
        }
        if _anyMatch(in: q, of: ["pause", "stop ", "skip ", "next track",
                                 "previous track"]) {
            return _hashPick(q, ["on it", "doing that now"])
        }
        if _anyMatch(in: q, of: ["write ", "note ", "jot ", "add note",
                                 "make a note", "save "]) {
            // Warmer than the prior "jotting it down" (which read
            // secretary-coded). "noted" especially feels like a
            // friend acknowledging, not a corporate assistant.
            return _hashPick(q, ["noted", "writing it down", "got it"])
        }
        if _anyMatch(in: q, of: ["remind me ", "remind", "set a reminder"]) {
            // Prior copy ("adding the reminder", "setting that up")
            // read as a workflow tool. "reminding you" is the same
            // information delivered as a person would say it.
            return _hashPick(q, ["noted", "reminding you", "got it"])
        }
        if _anyMatch(in: q, of: ["schedule ", "book ", "put on my calendar",
                                 "add to calendar"]) {
            // "on the calendar" reads like a friend telling you
            // they wrote it down. "scheduling that" / "putting it on
            // the calendar" both read like a Google Cal product tour.
            return _hashPick(q, ["on the calendar", "marking that",
                                 "got it down"])
        }
        if _anyMatch(in: q, of: ["send ", "email ", "message ", "text ",
                                 "reply", "draft"]) {
            // The original complaint that triggered this whole
            // pass — "drafting that" sounded like corporate
            // assistant copy. "writing it" is the same intent
            // delivered with zero clinical undertone.
            return _hashPick(q, ["writing it", "okay, writing", "got you"])
        }
        if _anyMatch(in: q, of: ["what is", "what's ", "tell me ",
                                 "explain ", "how does ", "who is"]) {
            return _hashPick(q, ["looking it up", "checking on that"])
        }
        if _anyMatch(in: q, of: ["check ", "find ", "look up ", "google ",
                                 "search "]) {
            return _hashPick(q, ["checking on it", "looking that up"])
        }
        if _anyMatch(in: q, of: ["delete ", "remove ", "clear ", "trash "]) {
            return _hashPick(q, ["cleaning that up", "on it"])
        }
        if _anyMatch(in: q, of: ["copy ", "move ", "rename "]) {
            return _hashPick(q, ["moving that around", "on it"])
        }
        if _anyMatch(in: q, of: ["take a screenshot", "screenshot",
                                 "capture "]) {
            return "grabbing the screen"
        }
        if _anyMatch(in: q, of: ["close ", "quit "]) {
            return "closing that"
        }

        // Default — varied pool so consecutive ambiguous prompts don't
        // produce the same opener. Hash on the prompt to keep retries
        // stable. The pool is intentionally warmer than just "on it"
        // (which reads like a help-desk bot) — "let me look", "yeah",
        // and "hmm" feel like a person thinking. The conversational
        // shapes above already handle the common "this should sound
        // human" cases (hi / thanks / what / etc).
        return _hashPick(q, [
            "on it",
            "let me look",
            "yeah",
            "hmm",
            "got it",
            "let me see",
        ])
    }

    // MARK: - Helpers

    /// Match short conversational shapes (greetings, thanks, "huh?",
    /// "wow") on the EXACT trimmed-and-punctuation-stripped string so
    /// that wrapping a real task in a greeting ("hey, can you ...")
    /// doesn't trigger the social ack — the action-verb match below
    /// will fire on that path instead.
    ///
    /// Each bucket has a small pool so the same input always yields a
    /// stable ack within a user's session (deterministic hash pick),
    /// but varies across users / prompts.
    private static func _socialPhrase(bare: String) -> String? {
        // Greetings — match the user's register. Klo should not say
        // "on it" when the user says "hi"; that reads like a help-desk
        // bot. "yeah?" feels like a friend looking up.
        let greetings: Set<String> = [
            "hey", "hi", "hello", "yo", "sup", "hola",
            "hey there", "hi there", "yo yo",
            "what's up", "whats up", "wassup",
            "morning", "good morning",
            "afternoon", "good afternoon",
            "evening", "good evening",
            "g'day", "howdy",
        ]
        if greetings.contains(bare) {
            return _hashPick(bare, [
                "hey",
                "what's up",
                "yeah?",
                "here for you",
                "ready when you are",
            ])
        }

        // Thanks — short forms only. "thanks for the meeting brief"
        // is a real task and should fall through.
        let thanks: Set<String> = [
            "thanks", "thank you", "ty", "thx",
            "tysm", "thanks!", "thank u", "appreciate it",
            "appreciated", "much appreciated",
        ]
        if thanks.contains(bare) {
            return _hashPick(bare, [
                "anytime",
                "you got it",
                "no worries",
                "all good",
            ])
        }

        // Sorry / never-mind — quiet, non-judgmental ack.
        let walkbacks: Set<String> = [
            "sorry", "my bad", "oops",
            "nevermind", "never mind", "nvm",
            "scratch that", "ignore that", "wait",
        ]
        if walkbacks.contains(bare) {
            return _hashPick(bare, [
                "all good",
                "no worries",
                "you're set",
            ])
        }

        // Plain acknowledgments. The user is closing a loop, not
        // opening a task. Klo should match their brevity.
        let acks: Set<String> = [
            "ok", "okay", "k", "kk", "cool", "sure",
            "yeah", "yes", "yep", "yup", "yea",
            "no", "nope", "nah", "got it",
            "right", "alright",
        ]
        if acks.contains(bare) {
            return _hashPick(bare, [
                "yeah",
                "got you",
                "okay",
            ])
        }

        // Casual reactions — match the energy.
        let reactions: Set<String> = [
            "lol", "lmao", "lmfao", "haha", "ha",
            "wow", "omg", "whoa", "nice", "neat",
            "huh interesting", "interesting",
        ]
        if reactions.contains(bare) {
            return _hashPick(bare, [
                "ha",
                "yeah",
                "right?",
            ])
        }

        // "?" or "huh?" or "what?" alone — the user is prompting klo
        // to elaborate, not asking a question.
        let pings: Set<String> = [
            "?", "??", "???",
            "huh", "what", "hmm", "hmmm",
        ]
        if pings.contains(bare) {
            return _hashPick(bare, [
                "yeah?",
                "sup?",
                "what's on your mind",
            ])
        }

        // Identity / capability inquiries — calm + curious, not
        // robotic ("I am klo, an AI assistant..."). Single-line
        // openers; the model fills in the actual answer.
        let identityFragments = [
            "what can you do",
            "what do you do",
            "who are you",
            "what are you",
            "can you help",
            "are you there",
            "you there",
            "you up",
        ]
        for fragment in identityFragments where bare.contains(fragment) {
            return _hashPick(bare, [
                "sure, what's up",
                "happy to",
                "what do you need",
            ])
        }

        return nil
    }

    private static func _anyMatch(in s: String, of needles: [String]) -> Bool {
        for n in needles {
            if s.contains(n) {
                return true
            }
        }
        return false
    }

    private static func _hashPick(_ seed: String, _ options: [String]) -> String {
        guard !options.isEmpty else { return "on it" }
        return options[abs(seed.hashValue) % options.count]
    }
}
