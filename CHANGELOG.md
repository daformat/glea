# Changelog

What changed in each release of Glea.

## 0.15.8 Beta — 2026-10-10

- Glea Clipper for Safari keeps the popup's Into and Open Glea afterwards
  as you set them, and point and shoot follows them: a new note is named
  after the page.

## 0.15.7 Beta — 2026-10-10

- Glea Clipper for Safari no longer says "Collected to Today" after point
  and shoot: it can't know where the capture went.
- Images linked by their bare name are found in your assets folder, like
  Obsidian's.
- The chevrons on All Notes' groups show in the dark theme.

## 0.15.6 Beta — 2026-10-09

- Point and shoot's spotlight glides from block to block, and a selection
  lights up as one rounded shape.
- Text selected inside a page's web components can be collected too.

## 0.15.5 Beta — 2026-10-08

- Tables too wide for the page scroll sideways (swipe, or Shift and the
  wheel) instead of running off it, the cell you're editing scrolling into
  view.
- While you're in a table, a + on its bottom edge adds a row and one on its
  right edge adds a column.
- Tables in quotes and callouts show as tables, and Enter and Tab keep new
  rows in the quote.
- A table's grip lines up with its header, like other blocks'.

## 0.15.4 Beta — 2026-10-08

- Notes stay put as images and embeds load above what you're reading,
  whether you scrolled there or jumped to a section.
- Jumping to a section (a link or the table of contents) lands on its
  heading even while media above it load, and its highlight follows it.
- Opening another note no longer blanks its videos and embeds a moment
  before the new note shows.
- A dropped block glides into its new place without a jump at the end,
  its image source fading in as it lands.
- Links in headings keep the heading's size.

## 0.15.3 Beta — 2026-10-04

- Glea Clipper for Safari comes with Glea: turn it on in Safari ▸ Settings
  ▸ Extensions to point and shoot in Safari, and collect selections,
  articles, images and links into Glea.

## 0.15.2 Beta — 2026-10-04

- Search suggestions come from the search engine you chose (DuckDuckGo,
  Kagi or Bing have their own), so what you type only goes to that engine.

## 0.15.1 Beta — 2026-10-04

- "Collected to" and the capture picker stay on the window when it moves.
- Option-Return in the capture picker collects, instead of creating a
  note with an empty name.

## 0.15.0 Beta — 2026-10-04

- Automatic updates: Glea checks in the background, downloads new versions
  on its own, and shows a "Relaunch to Update" pill in the top bar when one
  is ready. Glea ▸ Check for Updates… checks now.
- Downloads and source on GitHub: github.com/daformat/glea, and the Glea
  Clipper browser extensions at github.com/daformat/glea-extensions.
- Glea is in beta: its version now says so.

## 0.14.0 — 2026-10-04

- Glea Clipper browser extensions (Chrome, Firefox, Safari) collect
  into Glea through glea://capture: point and shoot, selections,
  articles, images and links.
- Point and shoot shows on Reddit and leaves icons out of captures.
- Long notes open faster, styled from the top a part at a time.
- Smooth window resizing: text, media and the gutter follow as you drag.
- Long sections open visibly; images in list items get room below them.
- A styled installer disk image.

## 0.13.0 — 2026-10-04

- PDFs in notes like any other media, in a native viewer that scrolls
  once clicked and hands the scroll back to the note at its ends.
- Resize images, videos and PDFs by dragging a handle; the width is
  saved in the note's Markdown.
- Clickable links and foldable "N more" in linked and unlinked
  references, with properly indented list items.
- Source available under the PolyForm Strict License.

## 0.12.2 — 2026-10-04

- A + button in the top bar makes a new note.
- Link buttons for unlinked references sit on each note's title line and
  show while hovering the whole block; linked references sort A to Z.
- Hover highlights no longer stay stuck when the page scrolls.

## 0.12.1 — 2026-10-03

- The page stays put when a line turns into a heading near its edge.
- The table of contents rubber-bands; All Notes fades under its top edge.

## 0.12.0 — 2026-10-03

- Note groups: drag notes onto each other in All Notes to group them,
  with collapsing, renaming, undo and a table of contents for the groups.
- More blocks in the slash menu: callouts, math, media files, web embeds
  and embedded notes.
- All Notes on ⇧⌘H, and fixes to callouts, the cursor and inline code.

## 0.11.1 — 2026-10-02

- Math source is syntax colored while it's being edited.
- The notes list has room at its bottom, and its checkboxes no longer stay
  after scrolling.

## 0.11.0 — 2026-10-02

- Obsidian compatibility: links to headings and blocks, ![[embeds]] of
  files and notes (rendered in place), frontmatter properties, aliases and
  tags, #tags, ==highlights==, %%comments%% and callouts. The link menu
  completes headings and blocks, and "#" completes tags.

## 0.10.1 — 2026-10-01

- Long formulas fit the column: blocks break into lines at their
  operators, inline formulas wrap with the text, and both re-fit as the
  window resizes.

## 0.10.0 — 2026-10-01

- Math in notes: `$…$` and `$$…$$` LaTeX, typeset as you write. Click a
  formula to edit its source where you clicked; "\" offers LaTeX commands,
  Tab moves between their arguments.

## 0.9.1 — 2026-10-01

- ⌘↩ searches the web for the word at the cursor or the selection (⌥⌘↩:
  the sentence) and links the searched text to the search.
- Switching between the web and the notes keeps the cursor where it was.
- Typing is fast again on long notes.
- No white line around web pages in light mode; the active tab stands out
  more.

## 0.9.0 — 2026-10-01

- Folding sections and expanding, collapsing or loading embeds and images
  animate smoothly, however long the note.
- Tables wrap to fit and are edited in place; a toggle on hover switches
  a table to Markdown and back.
- Reference previews render Markdown.
- Embeds near the screen load first and no longer take the focus.
- Selected embeds and images show the selection.
- Yesterday's summary can be closed.
- Faster rendering of long notes, and crash fixes.

## 0.8.0 — 2026-09-30

- Point and shoot collects YouTube videos and X, Bluesky and Instagram
  posts as embeds, on those sites and on pages that embed them. Hold
  ⌥⌘ to collect their text instead.
- The Collected toast links to the note, stays longer, and stays while
  hovered.
- Fixes crashes when clicking links in notes.

## 0.7.4 — 2026-09-30

- Daily summary: today's journal recaps what you worked on and read on
  your last active day, and suggests where to pick up.
- Typing [[ in a note opens a menu of notes to link to, styled like the
  slash menu, with an option to link to a new note.

## 0.7.3 — 2026-09-30

- The journal's table of contents keeps Today on top, with earlier days
  and their headings nested one level below.
- The table of contents' dashes keep their size while a long note
  scrolls.

## 0.7.2 — 2026-09-30

- Unlinked references: under a note's backlinks, the places where its
  name appears as plain text, with Link and Link All buttons.
- Point and shoot targets and hugs page content with new, faster
  heuristics (text runs, media, scroll containers, web components).
- Refreshed tab group colors and top bar grays.
