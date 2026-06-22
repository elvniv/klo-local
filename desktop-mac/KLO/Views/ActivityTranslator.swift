import Foundation

/// Pure function: raw tool-call payload → friendly first-person copy.
///
/// The sidecar emits `step_progress` events with a tool name + action +
/// detail. Detail carries the literal arg payload — for AppleScript that
/// can be the full script body. Previously KLOState rendered that
/// directly ("asking tell application Notes…" → "ASKING TELL" after
/// truncation), which is gibberish to non-technical users.
///
/// This translator collapses raw tool calls into the kind of phrasing a
/// person would use to describe what's happening — "opening your notes",
/// "writing that down", "putting on some music". Returns `nil` for tool
/// calls that are too granular to surface (single keypresses,
/// accessibility index reads, mouse moves, screenshots between steps);
/// the caller treats nil as "say nothing this turn".
///
/// Phrasing variants per bucket so back-to-back identical tools don't
/// produce identical bubbles — variety picked by hashing the detail
/// string so the same call deterministically produces the same phrase
/// across retries.
enum ActivityTranslator {

    /// Single entry point. Returns the bubble copy, or nil to suppress.
    /// Callers in KLOState invoke this from `noteToolActivity(...)`.
    static func translate(name: String, action: String?, detail: String?) -> String? {
        let n = (name).lowercased()
        let a = (action ?? "").lowercased()
        let d = detail ?? ""

        // Granular noise — never surface. Mouse moves and screenshots
        // fire dozens of times per task; a bubble per call would look
        // like seizure-mode.
        let suppress: Set<String> = [
            "screenshot", "mouse_move", "wait", "get_cursor_position",
        ]
        if suppress.contains(n) || suppress.contains(a) {
            return nil
        }

        // Tool-specific buckets.
        switch n {
        case "shell":
            return _shellPhrase(cmd: d)
        case "applescript":
            return _applescriptPhrase(script: d, intent: a)
        case "computer":
            return _computerPhrase(action: a, detail: d)
        case "web":
            return _webPhrase(action: a, detail: d)
        case "accessibility":
            return _accessibilityPhrase(action: a)
        case "memory_remember":
            return _pick(["writing that down for next time",
                          "saving that as a preference",
                          "remembering that"], seed: d)
        case "memory_recall":
            return _pick(["checking what i remember about you",
                          "looking through what i've learned"], seed: d)
        case "task_complete", "handoff_to_user", "i_couldnt_do_this":
            // These ARE the terminal events — the result panel handles
            // them. No bubble needed; would just flash and immediately
            // dismiss with the run.
            return nil
        case "confirm_action":
            return "asking you to confirm"
        case "request_permission":
            return "asking macOS for access"
        case "composio_list_actions":
            return _pick(["finding the right action",
                          "looking up what's available"], seed: d)
        case "composio_execute":
            // Detail for composio_execute carries the action slug
            // (e.g. "GMAIL_LIST_THREADS", "CALENDAR_CREATE_EVENT").
            // Parse the toolkit + action and translate to specific
            // copy instead of falling through to "doing that for you".
            return _composioPhrase(detail: d, action: a)
        case "schedule_task":
            return "scheduling that"
        case "delegate_task":
            return "passing this along"
        case "read_file":
            return _pick(["reading that file",
                          "having a look at the file"], seed: d)
        case "write_file":
            return _pick(["writing that file",
                          "saving that down"], seed: d)
        default:
            // Unknown tool — fall back to something inoffensive rather
            // than leaking the name.
            return _pick(["working on it", "just a sec"], seed: n + d)
        }
    }

    // MARK: - Per-tool buckets

    private static func _shellPhrase(cmd: String) -> String? {
        let c = cmd.lowercased()
        // Match the command verb (first non-pipe / non-redirect token).
        let head = c
            .split(whereSeparator: { " ;|&".contains($0) })
            .first.map(String.init) ?? c
        let verb = head.split(separator: "/").last.map(String.init) ?? head

        switch verb {
        case "date", "cal", "uptime":
            return "checking the time"
        case "ls", "find", "fd", "tree":
            return "looking around your files"
        case "grep", "rg", "ag":
            return "searching through that"
        case "cat", "head", "tail", "less", "more":
            return "reading that"
        case "open":
            return _pick(["opening it up", "opening that for you"], seed: cmd)
        case "ps", "top", "htop":
            return "checking what's running"
        case "df", "du":
            return "checking disk space"
        case "curl", "wget", "http":
            return "fetching that"
        case "git":
            return "looking at the git status"
        case "ping", "nslookup", "dig":
            return "checking the network"
        case "echo", "printf":
            return nil  // too granular, probably part of a chain
        case "mkdir", "touch":
            return "making space for that"
        case "rm", "mv", "cp":
            return _pick(["tidying up", "moving things around"], seed: cmd)
        default:
            return _pick(["running a quick check",
                          "doing a quick check"], seed: cmd)
        }
    }

    private static func _applescriptPhrase(script: String, intent: String) -> String? {
        let s = script.lowercased()
        let app = _extractTellApp(from: s)
        let isWrite = intent == "write" || _scriptLooksLikeWrite(s)

        // App-specific phrasing.
        if let app = app {
            switch app {
            case "notes":
                if isWrite {
                    if s.contains("make new note") || s.contains("create note") {
                        return _pick(["writing it in Notes",
                                      "jotting that down in Notes",
                                      "adding it to your notes"], seed: script)
                    }
                    return _pick(["updating your notes",
                                  "making changes in Notes"], seed: script)
                }
                return _pick(["checking your notes",
                              "looking through your notes"], seed: script)

            case "reminders":
                if isWrite {
                    return _pick(["adding to your reminders",
                                  "putting that in Reminders"], seed: script)
                }
                return "checking your reminders"

            case "calendar":
                if isWrite {
                    return _pick(["putting that on your calendar",
                                  "scheduling that"], seed: script)
                }
                return _pick(["checking your calendar",
                              "looking at your calendar"], seed: script)

            case "music":
                if s.contains("pause") { return "pausing the music" }
                if s.contains("next track") { return "skipping to the next track" }
                if s.contains("previous track") { return "going back a track" }
                if s.contains("set sound volume") { return "adjusting the volume" }
                if s.contains("play") {
                    return _pick(["putting on some music",
                                  "playing that for you"], seed: script)
                }
                return _pick(["working with Music",
                              "checking what's playing"], seed: script)

            case "spotify":
                if s.contains("pause") { return "pausing Spotify" }
                if s.contains("play") {
                    return _pick(["putting it on in Spotify",
                                  "playing that on Spotify"], seed: script)
                }
                return "working with Spotify"

            case "mail":
                if s.contains("make new outgoing message") || s.contains("make new message") {
                    return _pick(["drafting that email",
                                  "starting an email"], seed: script)
                }
                if isWrite {
                    return "updating Mail"
                }
                return _pick(["checking your mail",
                              "looking through your inbox"], seed: script)

            case "messages":
                return _pick(["sending that message",
                              "drafting the message"], seed: script)

            case "safari", "google chrome", "chrome", "arc", "dia":
                return _pick(["working in the browser",
                              "having a look in the browser"], seed: script)

            case "finder":
                return _pick(["working in Finder",
                              "looking through your files"], seed: script)

            case "system events":
                // SystemEvents is the generic key/click driver; usually
                // a step in a chain rather than the main action.
                return nil

            default:
                let appCap = app.prefix(1).uppercased() + app.dropFirst()
                if isWrite {
                    return _pick(["doing a quick thing in \(appCap)",
                                  "working in \(appCap)"], seed: script)
                }
                return _pick(["having a peek at \(appCap)",
                              "checking \(appCap)"], seed: script)
            }
        }

        // No tell-app found; generic fallback.
        return isWrite
            ? _pick(["making a quick change",
                     "writing that down"], seed: script)
            : _pick(["having a peek",
                     "checking on that"], seed: script)
    }

    private static func _computerPhrase(action: String, detail: String) -> String? {
        switch action {
        case "open_app":
            // Detail for open_app is usually the app name.
            let app = detail.isEmpty ? "" : " " + detail
            return "opening\(app.isEmpty ? " it up" : app)"
        case "click_element", "left_click", "click", "double_click":
            return _pick(["tapping that for you",
                          "clicking through"], seed: detail)
        case "right_click":
            return "opening the right-click menu"
        case "type", "type_text":
            return _pick(["typing it out",
                          "filling that in"], seed: detail)
        case "key", "key_combo":
            // Surface only the meaningful shortcuts (cmd+s, cmd+f), not
            // every arrow/tab keypress.
            let d = detail.lowercased()
            if d.contains("cmd+s") || d.contains("⌘s") { return "saving it" }
            if d.contains("cmd+f") || d.contains("⌘f") { return "looking through that" }
            if d.contains("cmd+a") || d.contains("⌘a") { return "selecting it all" }
            if d.contains("return") || d.contains("enter") { return nil }
            return nil
        case "scroll":
            return nil  // too granular
        default:
            return nil
        }
    }

    private static func _webPhrase(action: String, detail: String) -> String? {
        switch action {
        case "navigate", "open", "tabs_navigate":
            let host = _extractHost(from: detail)
            if let host = host {
                return "loading \(host)"
            }
            return "loading that page"
        case "snapshot", "dom_snapshot", "tabs_dom_snapshot":
            return nil  // too granular
        case "screenshot":
            return nil
        case "click", "click_idx", "tabs_click_idx":
            return _pick(["clicking through",
                          "tapping that for you"], seed: detail)
        case "fill", "fill_label", "tabs_fill":
            return _pick(["filling that in",
                          "typing it into the field"], seed: detail)
        case "wait_for", "wait":
            return "waiting for the page"
        case "find", "tabs_find":
            return "looking for that on the page"
        case "read_text", "tabs_read_text":
            return "reading the page"
        default:
            return nil
        }
    }

    private static func _accessibilityPhrase(action: String) -> String? {
        switch action {
        case "press", "click", "perform":
            return _pick(["tapping that for you",
                          "clicking through"], seed: action)
        case "actionable_index", "snapshot":
            return nil  // index reads are noise
        case "set_value_indexed", "set_value", "menu_select":
            return _pick(["filling that in",
                          "picking that option"], seed: action)
        default:
            return nil
        }
    }

    // MARK: - Helpers

    /// Translate a Composio action slug into specific, friendly copy.
    /// Composio actions follow the pattern `TOOLKIT_VERB[_NOUN]` —
    /// GMAIL_LIST_THREADS, CALENDAR_CREATE_EVENT, NOTION_CREATE_PAGE,
    /// LINEAR_CREATE_ISSUE, etc. We parse the toolkit prefix +
    /// matched verb pattern to produce phrases like "checking your
    /// inbox" instead of leaking the raw slug.
    ///
    /// `detail` carries the action slug (whatever the agent passed
    /// as the action= arg). When unparseable, falls back to a
    /// generic "doing that for you" rather than leaking the slug.
    private static func _composioPhrase(detail: String, action: String) -> String? {
        let slug = (detail.isEmpty ? action : detail).uppercased()
        // Pull the leading toolkit token + the rest of the verb.
        let parts = slug.split(separator: "_", maxSplits: 1)
        let toolkit = parts.first.map(String.init)?.lowercased() ?? ""
        let verb = parts.count > 1 ? String(parts[1]).lowercased() : ""

        switch toolkit {
        // ─── email ────────────────────────────────────────────────
        case "gmail", "googlemail", "outlook":
            if verb.contains("send") {
                return _pick(["sending that off",
                              "sending the email"], seed: slug)
            }
            if verb.contains("list") || verb.contains("fetch")
                || verb.contains("get") || verb.contains("search") {
                return _pick(["checking your inbox",
                              "having a look at your inbox"], seed: slug)
            }
            if verb.contains("draft") || verb.contains("create") {
                return _pick(["drafting that email",
                              "starting the email"], seed: slug)
            }
            if verb.contains("delete") || verb.contains("trash") {
                return "cleaning that up"
            }
            if verb.contains("reply") {
                return _pick(["drafting the reply",
                              "writing back"], seed: slug)
            }
            if verb.contains("label") {
                return "tagging that"
            }
            return _pick(["working with your email",
                          "checking on that"], seed: slug)

        // ─── calendar ──────────────────────────────────────────────
        case "calendar", "googlecalendar":
            if verb.contains("create") || verb.contains("add") {
                return _pick(["putting that on your calendar",
                              "scheduling that"], seed: slug)
            }
            if verb.contains("list") || verb.contains("get")
                || verb.contains("fetch") || verb.contains("search") {
                return _pick(["checking your calendar",
                              "looking at your schedule"], seed: slug)
            }
            if verb.contains("update") {
                return "updating that event"
            }
            if verb.contains("delete") || verb.contains("cancel") {
                return "removing that event"
            }
            return _pick(["checking your calendar",
                          "working with your calendar"], seed: slug)

        // ─── notion ────────────────────────────────────────────────
        case "notion":
            if verb.contains("create") {
                return _pick(["adding it to Notion",
                              "writing it into Notion"], seed: slug)
            }
            if verb.contains("search") || verb.contains("query") {
                return "searching Notion"
            }
            if verb.contains("update") {
                return "updating Notion"
            }
            return _pick(["working in Notion",
                          "checking Notion"], seed: slug)

        // ─── linear ────────────────────────────────────────────────
        case "linear":
            if verb.contains("create") {
                return _pick(["filing that in Linear",
                              "creating the Linear issue"], seed: slug)
            }
            if verb.contains("update") {
                return "updating Linear"
            }
            if verb.contains("list") || verb.contains("get")
                || verb.contains("search") {
                return "checking Linear"
            }
            return "working in Linear"

        // ─── github ────────────────────────────────────────────────
        case "github":
            if verb.contains("create") && verb.contains("issue") {
                return "filing that GitHub issue"
            }
            if verb.contains("create") && verb.contains("pr") {
                return "opening the pull request"
            }
            if verb.contains("create") {
                return "creating that in GitHub"
            }
            if verb.contains("comment") {
                return "commenting on GitHub"
            }
            return "working in GitHub"

        // ─── slack ─────────────────────────────────────────────────
        case "slack":
            if verb.contains("send") || verb.contains("post") {
                return _pick(["sending that to Slack",
                              "posting the Slack message"], seed: slug)
            }
            if verb.contains("list") || verb.contains("search") {
                return "checking Slack"
            }
            return "working in Slack"

        // ─── docs / sheets / drive ─────────────────────────────────
        case "googledocs", "docs":
            return verb.contains("create")
                ? "starting that doc"
                : "working with your docs"
        case "googlesheets", "sheets":
            return verb.contains("update") || verb.contains("write")
                ? "updating the sheet"
                : "checking the sheet"
        case "googledrive", "drive":
            return verb.contains("search")
                ? "searching your Drive"
                : "working with your Drive"

        // ─── contacts ──────────────────────────────────────────────
        case "googlecontacts", "contacts":
            return "looking up that contact"

        // ─── meet / zoom ───────────────────────────────────────────
        case "googlemeet", "meet":
            return verb.contains("create")
                ? "setting up the meeting"
                : "working with Meet"
        case "zoom":
            return verb.contains("create")
                ? "setting up the Zoom"
                : "working with Zoom"

        // ─── unknown toolkit ───────────────────────────────────────
        default:
            // Don't leak the slug. Generic but inoffensive.
            return _pick(["doing that for you",
                          "running that through"], seed: slug)
        }
    }

    /// Match `tell application "..."` and return the bare app name
    /// lowercased. Returns nil if the script doesn't start with a tell
    /// block (e.g. raw `do shell script`).
    private static func _extractTellApp(from script: String) -> String? {
        // Match: tell application "AppName"  (case-insensitive)
        let pattern = #"tell\s+application\s+["“]([^"”]+)["”]"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(script.startIndex..., in: script)
        guard let m = re.firstMatch(in: script, options: [], range: range),
              let r = Range(m.range(at: 1), in: script) else {
            return nil
        }
        return String(script[r]).lowercased()
    }

    /// Heuristic: does this script look like it mutates state? Used when
    /// `intent` isn't passed reliably from the sidecar's step_progress.
    private static func _scriptLooksLikeWrite(_ script: String) -> Bool {
        let writeVerbs = [
            "make new", "create ", "set ", "delete ", "play", "pause",
            "stop", "open ", "duplicate ", "move ", "add ",
        ]
        return writeVerbs.contains { script.contains($0) }
    }

    /// Extract a hostname from a URL-ish string for "loading example.com"
    /// copy. Returns nil if we can't parse one cleanly.
    private static func _extractHost(from urlish: String) -> String? {
        let trimmed = urlish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host else {
            return nil
        }
        // Strip leading "www." for a cleaner read.
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Deterministic variant picker — same seed → same phrase across
    /// retries. Lets us add variety without flickering between renders
    /// of the same logical activity.
    private static func _pick(_ options: [String], seed: String) -> String {
        guard !options.isEmpty else { return "" }
        let hash = seed.hashValue
        let idx = abs(hash) % options.count
        return options[idx]
    }
}
