/* extension/lib/composio.js — JS port of the native brand style model.
 *
 * Same palette + name overrides + slug list + djb2 color-from-slug
 * algorithm so the extension renders every toolkit identically to the
 * iOS app. Loaded as a classic <script> in sidepanel.html, and read by
 * overlay.js via importScripts-style fetch when the shadow DOM mounts.
 *
 * Public API:
 *   Composio.BUNDLED_SLUGS    — Set of known toolkit slugs
 *   Composio.displayName(slug, catalogName?)
 *   Composio.monogram(slug, catalogName?)
 *   Composio.color(slug)      — returns "#rrggbb" deterministic palette
 *   Composio.iconURL(slug)    — chrome-extension URL for the bundled PNG, or null
 *   Composio.matchPrefix(prefix) — sorted slugs matching `/<prefix>` autocomplete
 */
(function (root) {
  const PALETTE = [
    "#F07370", "#F4A857", "#E5CC5C", "#94CC6B", "#61C79E",
    "#57AEE0", "#7580EB", "#B375EB", "#EB75C7", "#D78F66",
    "#80BCBC", "#C7B885",
  ];

  const NAME_OVERRIDES = {
    gmail: "Gmail",
    googlecalendar: "Google Calendar",
    googledrive: "Google Drive",
    googlesheets: "Google Sheets",
    googledocs: "Google Docs",
    slack: "Slack",
    notion: "Notion",
    linear: "Linear",
    github: "GitHub",
    gitlab: "GitLab",
    asana: "Asana",
    trello: "Trello",
    jira: "Jira",
    discord: "Discord",
    zoom: "Zoom",
    dropbox: "Dropbox",
    salesforce: "Salesforce",
    hubspot: "HubSpot",
    stripe: "Stripe",
    twilio: "Twilio",
  };

  // The 20 slugs bundled as PNGs under extension/composio/. Mirrors
  // BrandStyle.bundledSlugs on iOS. New toolkits ship by adding the
  // PNG + the entry here.
  const BUNDLED_SLUGS = new Set([
    "gmail", "googlecalendar", "googledrive", "googlesheets", "googledocs",
    "slack", "notion", "linear", "github", "gitlab",
    "asana", "trello", "jira", "discord", "zoom",
    "dropbox", "salesforce", "hubspot", "stripe", "twilio",
  ]);

  function displayName(slug, catalogName) {
    if (catalogName && catalogName.indexOf(" ") !== -1) return catalogName;
    const k = String(slug || "").toLowerCase();
    if (NAME_OVERRIDES[k]) return NAME_OVERRIDES[k];
    return k
      .replace(/[_-]/g, " ")
      .split(" ")
      .map((p) => p.charAt(0).toUpperCase() + p.slice(1).toLowerCase())
      .join(" ");
  }

  function monogram(slug, catalogName) {
    const name = displayName(slug, catalogName || (slug && slug[0]?.toUpperCase() + slug.slice(1)));
    const words = name.split(" ").filter(Boolean);
    if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
    // CamelCase split
    for (let i = 1; i < name.length; i++) {
      if (name[i] >= "A" && name[i] <= "Z") {
        return (name[0] + name[i]).toUpperCase();
      }
    }
    return name.slice(0, 2).toUpperCase();
  }

  // djb2 hash → palette index. Same algorithm as BrandStyle.color so
  // the same slug picks the same color across surfaces.
  function color(slug) {
    let h = 5381;
    const s = String(slug || "").toLowerCase();
    for (let i = 0; i < s.length; i++) {
      h = ((h * 33) + s.charCodeAt(i)) >>> 0;
    }
    return PALETTE[h % PALETTE.length];
  }

  function iconURL(slug) {
    const k = String(slug || "").toLowerCase();
    if (!BUNDLED_SLUGS.has(k)) return null;
    // In a content script (shadow DOM overlay) chrome.runtime.getURL
    // is available; in a service worker too. The path matches the
    // web_accessible_resources entry registered in manifest.json.
    try { return chrome.runtime.getURL(`composio/${k}.png`); }
    catch (_) { return `composio/${k}.png`; }
  }

  function matchPrefix(prefix) {
    const p = String(prefix || "").toLowerCase();
    if (!p) return [];
    const slugs = Array.from(BUNDLED_SLUGS).sort();
    return slugs.filter((slug) => {
      if (slug.startsWith(p)) return true;
      const flat = displayName(slug).replace(/\s+/g, "").toLowerCase();
      return flat.startsWith(p);
    });
  }

  root.Composio = {
    BUNDLED_SLUGS,
    PALETTE,
    displayName,
    monogram,
    color,
    iconURL,
    matchPrefix,
  };
})(typeof window !== "undefined" ? window : self);
