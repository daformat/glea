# Glea

A minimal macOS web browser built on Chromium, inspired by [Beam](https://github.com/beamlegacy/beam).
It has a daily journal, linked notes, a unified omnibox, and point-and-shoot capture from web pages.
Everything you write is a plain Markdown file on disk.

- **Engine:** Chromium via the [Chromium Embedded Framework](https://github.com/chromiumembedded/cef) (CEF 154), one browser per tab.
- **App:** native AppKit, written in Swift. A thin Objective-C++ bridge wraps CEF's C++ API.

## Build and run

Requirements: macOS 12+ on Apple silicon, Xcode (Swift 6 toolchain), CMake and Ninja (`brew install cmake ninja`).

```bash
./scripts/setup_cef.sh
```

```bash
cmake -G Ninja -B build && ninja -C build
```

```bash
open build/Glea.app
```

`setup_cef.sh` downloads the CEF binary distribution (~130 MB) into `third_party/cef` and verifies its checksum.

That stock build can't play H.264 or AAC. Release builds use CEF built from source by `scripts/cef/build-cef.sh`, where macOS decodes them: H.264 with VideoToolbox, AAC with AudioToolbox. FFmpeg's own H.264 and AAC decoders are compiled out. The first build takes about 8 hours and ~100 GB; the patches it applies are in `scripts/cef/`.

## Features

### Journal and notes
- **Journal** (⇧⌘J): today's entry on top, previous days below, all editable in place.
- **Daily summary**, like Beam's: at the top of today's journal, a card recaps your last active day. It lists the notes you worked on, the pages you read (for 30 seconds or more, with the time spent) and where to pick up: the last note you edited and the longest page you read, unless you've gone back to them since. It's drawn by the app, not written into the journal file. *Hide* puts it away until the next day. Reading time counts only while Glea is in front and you've touched the keyboard or mouse in the last 90 seconds, and never in incognito windows. The record (`activity.json` in Application Support) keeps 30 days.
- **Notes**: create them from the omnibox, with ⌥⌘N, or by linking: `[[Note name]]` links are clickable, autocomplete after `[[`, and each note lists its **linked references** (backlinks).
- **Renaming** a note updates every `[[link]]` to it.
- **Unlinked references**, like Beam's: under the backlinks, a folded list of places where the note's name appears as plain text (whole words, not in code or links). *Link* turns one into a `[[link]]`, *Link All* does them all.
- **Live Markdown editor**: formatting converts as you type. `**bold**` turns bold the moment it's closed, and `# ` becomes a heading. A construct's syntax shows only while the cursor is inside it.
- **Rendered:** headings, bold and italic, links, bullets, checkboxes (click to toggle), quotes, code blocks (syntax highlighted from the fence's language, e.g. ```` ```swift ````), inline images and **tables**.
- **Math** (LaTeX): `$…$` in a line of text, `$$…$$` as a block (on one line or around several). Formulas show typeset and turn back into their source when the cursor goes in. Dollars with a space just inside them, like "$5 and $10", stay text.
- **Tables** (GFM):
  - Aligned columns, a header row and a grid.
  - Alignment follows the separator row (`:---:`, `---:`).
  - Tab and ⇧Tab move between cells, and Enter adds a row.
  - Typing a header row like `| a | b |` and pressing Enter turns it into a table.
  - *Format ▸ Insert Table* (⌥⌘T) adds one.
- **Formatting bar** on text selection: bold, italic, strikethrough, code, link, headings, quote, lists and tasks. The same commands are in the *Format* menu (⌘B, ⌘I, ⇧⌘X, ⌘E, ⇧⌘K, ⌥⌘1–3…).
- Enter continues lists, tasks and quotes. Tab and ⇧Tab indent list items. Typing `[] ` (or `[ ] `, `[x] `) at the start of a line makes a task.

### Storage
Everything lives in `~/Documents/Glea` (change it with *Glea ▸ Change Notes Folder…*):

```
notes/<Title>.md
journal/<yyyy-MM-dd>.md
assets/            images downloaded by captures
```

- Files edited by other apps are picked up live.
- *File ▸ Export All Notes as Markdown…* copies the whole folder. *Export Note as Markdown…* saves a single note.

### Point and shoot
Modelled on Beam and Kosmik.

- **Hold ⌥ Option** on a web page: the page dims and a spotlight morphs onto the block under the cursor, or onto your text selection.
  - It hugs the actual text and media, and respects scrolling containers.
  - It leans a few pixels towards the pointer, and shrinks to a dot over empty space.
- **Click** to collect: the spotlight presses down, springs back and flashes. A picker then asks where the capture goes (today's journal, an existing note, or a new one).
- **Drag** instead of clicking to capture any rectangular area as a screenshot.
- If there's nothing to collect, the spotlight shakes.
- **Posts and videos** on YouTube, X, Bluesky and Instagram (on those sites, or embedded in other pages) are spotlighted whole and collected as embeds: the note plays the video or shows the post. Hold **⌥⌘** instead of ⌥ to collect their text and images as usual.
- Captures are converted to Markdown: headings, lists, links, code, tables and images, with citation markers removed. Images are downloaded into `assets/`.
- Each capture is appended as a quote with a link back to the source page.
- ⌘S (*Collect Page*) saves the page itself as a link. The page's context menu also offers *Collect Selection* and *Collect Image*.

### Table of contents
Notes and the journal have a scroll-aware table of contents in the left margin, after [hello-mat.com's component](https://hello-mat.com/design-engineering/table-of-contents).

- At rest it shows one dash per heading, and the current heading's dash is brighter and longer.
- Hovering shrinks the dashes away and springs the titles in.
- Clicking scrolls to the heading and briefly highlights it.
- In the journal, days are the top-level entries.
- Headings added or removed slide and fade in and out.
- Hidden when there's only one heading.

### Motion
Timings follow Beam's: short ease-in-outs for state changes and firm springs for movement.

- The omnibox fades in while scaling up from 96%, and resizes with a spring as results change.
- The selected result glides between rows.
- Tabs slide, grow in and shrink out. Hover states cross-fade, and buttons dip when pressed.
- Switching between the web and notes cross-fades.
- The find bar drops in, and toasts rise.
- Motion is turned off when *Reduce motion* is enabled in System Settings.

### Omnibox
- **⌘T** (or ＋) shows the start page, with the omnibox inline; a tab appears once you choose something (⌘W or Esc goes back). **⌘K** opens the floating omnibox over the page. **⌘L** edits the current tab's address, and clicking the active tab does the same.
- One field for:
  - URLs and web search, with live suggestions (Google, DuckDuckGo, Kagi or Bing)
  - full-text note search
  - open tabs
  - browsing history
  - *Create Note: "…"* (⇧⌘↩)
- ⌘↩ or ⌘-click opens a result in a new tab (even while editing the current tab's address).

### Incognito
- **⇧⌘N** opens an incognito window: dark, with no tabs. Its start page explains what incognito means and has the omnibox inline. ⌘D switches to your journal and notes there too.
- Its tabs share an in-memory Chromium session: cookies and site data are erased when the window closes, and each incognito window starts fresh.
- Pages aren't added to history, the session isn't restored, and the omnibox leaves out history. There are no search suggestions, and favicons are fetched without a disk cache.
- Extensions don't run there (Chrome's default). Downloads and captures to notes are kept.

### Browser
- Tabs with favicons (hover a tab to see its URL), session restore, back and forward, find in page (⌘F), zoom, and downloads to `~/Downloads`.
- **Top bar:**
  - On the right: search, and one button that toggles between the web and your notes (⌘D, like Beam).
  - In notes mode, the tabs step aside for *Journal* and *All Notes*.
- **Tabs:** they shrink to a minimum width as more open, then scroll sideways (no scrollbar).
  - Hovering a tab shows its address (with a padlock for https) and a button to copy it; the active and hovered tabs have a hairline outline.
  - **Pinned tabs** sit at the left as icons. Links to other sites open in a new tab.
  - **Tab groups**, like Beam's: a colored capsule before the group's tabs and an underline beneath them. Click the capsule to collapse; right-click it to rename, recolor, add a tab, capture the group to a note, ungroup or close.
  - **Drag and drop** to reorder tabs and groups, pin or unpin, or move a tab into or out of a group (it joins as soon as the pointer is over the group). The strip auto-scrolls at its edges, and an invalid drop snaps back.
  - Hold **⌥** while dragging a tab over another to group them.
- **Extensions:** Chrome Web Store extensions install and run; the puzzle button lists them and opens their popups.
- **DevTools (⌥⌘I), docked like in Chrome:**
  - Dock right, bottom or left, or undock into a window, from the "Dock side" row of DevTools' ⋮ menu, or from *View ▸ Developer Tools*.
  - Resize with DevTools' own splitter. *Inspect Element* reveals the node.
  - The docked DevTools are Chrome's bundled frontend in a browser view, connected to the page through a private localhost WebSocket relay (CEF can't embed its native DevTools in a view).

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘T / ⌘L | New tab (start page) / edit the current tab's address |
| ⌘D | Toggle web ↔ journal & notes |
| ⇧⌘J / ⌥⇧⌘N | Journal / All notes |
| ⇧⌘N | New incognito window |
| ⌘N / ⌥⌘N | New window / new note |
| ⌘K | Omnibox (from anywhere) |
| ⌥⌘⌫ | Move note to Trash |
| ⌥ hold + click | Point and shoot |
| ⌥⌘ hold + click | Point and shoot, posts and videos as text |
| ⌘S | Collect page |
| ⌘W / ⇧⌘T | Close tab (or the window, once it has none) / reopen closed tab |
| ⌥⌘W | Close all tabs (pinned ones stay) and go back to the notes; ⇧⌘T reopens them all |
| ⌘1–9, ⇧⌘[ ⇧⌘], ⌥⌘← ⌥⌘→ | Switch tabs (Journal / All Notes in notes mode) |
| ⌘[ ⌘] ⌘R | Back, forward, reload |
| ⌘F, ⌘G | Find in page |
| ⌥⌘I | Developer tools (show / hide) |

## Architecture

```
src/bridge/            Objective-C++ — everything that touches CEF
  include/GleaBridge.h   the ObjC API Swift sees (module "GleaBridge")
  glea_main.mm           CEF init / message loop / shutdown, NSApplication subclass
  glea_browser_view.mm   GleaBrowserView (NSView per tab) + its CefClient
  helper_main.mm         helper processes; exposes __gleaNative.post() to pages
src/app/               Swift — the app
  BrowserWindowController  window, modes, tabs, overlays, menu actions
  TopBar, Omnibox          tab strip, find bar, omnibox, capture picker
  TableOfContents          scroll-aware table of contents
  Motion                   animation curves and helpers
  NoteViews                journal, note page (with backlinks), notes list
  MarkdownEditor           live-preview editor (TextKit 1, custom layout manager)
  SyntaxHighlighter        code block colors, one regex grammar per language
  NoteStore                Markdown files, search, backlinks, rename, captures
  BrowsingData             history, session, search engines, image cache
src/resources/content-script.js   point-and-shoot + HTML→Markdown, runs in pages
```

- **Why the bridge:** CEF's API is C++ classes you subclass, which Swift can't do.
- **Content script injection:** the script is passed to each browser at creation. The renderer process evaluates it in every main-frame context before page scripts run.
- **Page → app messages:** `__gleaNative.post(name, json)` sends a CEF process message to the browser process.

### Development

- `GLEA_DATA_DIR`, `GLEA_SUPPORT_DIR` and `GLEA_PROFILE_DIR` redirect notes, app state and the Chromium profile.
- `GLEA_TEST_HOOKS=1` lets scripts drive the UI through distributed notifications (see `TestHooks.swift`).

## Known limitations

- **Keychain:** local builds are only ad hoc signed, so Chromium runs with `--use-mock-keychain` to avoid a Keychain prompt after every rebuild. Cookies are therefore encrypted with a fixed key. Set `GLEA_REAL_KEYCHAIN=1` once the app is properly signed.
- **Permissions:** camera, microphone, location and notification requests are denied (CEF's default for embedded browsers).
- **Streaming and sign-in:** there's no DRM (Widevine), so Netflix and similar sites won't play. Some Google sign-in flows reject embedded browsers.
- **Scope:** no password manager, no sync.
- **Windows:** ⌘N opens another window, in the front window's mode (web or notes); every window and its tabs come back at launch. Closing the last tab (⌘W) closes a window, except the last one, which goes back to the notes. Closing a window closes its tabs: ⇧⌘T reopens them (in the window left in front, or, with none left, bringing the main window back), until Glea quits. Glea keeps running with every window closed: the Dock icon or ⌘N brings the main window back. It comes back in the notes, or in the mode (web or notes) of a window already open (incognito windows always open on the web); ⌘T brings the window back on the start page, ⇧⌘T with the last closed tabs.
- **DevTools:** the docked frontend reloads when moved between the page and its own window. The ⌘⇧D "toggle dock side" shortcut isn't wired.
- **Point and shoot:** works in a page's main frame, not inside iframes. Area capture uses Chromium's DevTools screenshot, which captures only the visible viewport.
- **Traffic lights:** they're repositioned by resizing AppKit's titlebar container. This uses the same technique as Electron but relies on private view layout.

## Credits

Glea's design is inspired by [Beam](https://github.com/beamlegacy/beam): its journal and notes, point and shoot, omnibox, tab groups and motion. No code or assets are taken from it.

Math is typeset by [SwiftMath](https://github.com/mgriebling/SwiftMath) (MIT License, © 2023 Computer Inspirations), vendored in `third_party/SwiftMath`, with the Latin Modern Math font (GUST Font License).
