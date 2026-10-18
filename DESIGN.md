---
name: Gleanary Native Library
description: Saved evidence, ready for conversation; a native macOS Library.
colors:
  ink: "#000000"
  inverse-ink: "#ffffff"
typography:
  title:
    fontFamily: "-apple-system"
    fontWeight: 700
  row-title:
    fontFamily: "-apple-system"
    fontWeight: 500
  body:
    fontFamily: "-apple-system"
    fontSize: "14pt"
  note-body:
    fontFamily: "Athelas (Georgia fallback)"
    fontSize: "14pt"
  metadata:
    fontFamily: "-apple-system"
rounded:
  search: "7pt"
  source-row: "8pt"
  preview-card: "12pt"
  composer: "24pt"
spacing:
  row-stack: "5pt"
  row-y: "7pt"
  compact: "8pt"
  row-gap: "10pt"
  standard: "14pt"
  handoff-bottom: "16pt"
  list-inset: "18pt"
  reading-stack: "20pt"
  sheet-inset: "24pt"
  reading-y: "28pt"
  reading-x: "32pt"
components:
  search:
    rounded: "{rounded.search}"
    padding: "{spacing.compact}"
  document-row:
    typography: "{typography.row-title}"
    padding: "7pt 0"
  preview-info:
    rounded: "{rounded.preview-card}"
    padding: "{spacing.standard}"
  preview-hero:
    rounded: "{rounded.preview-card}"
    height: "170pt"
  composer:
    rounded: "{rounded.composer}"
    padding: "9pt 12pt"
---

# Design System: Gleanary Native Library

Implementation reference for agents changing native Library and compatible
app controls. Refreshed 2026-10-15; use SwiftUI source for implementation
facts and this document for the design direction. The sidecar at
`.impeccable/design.json` records native bindings and illustrative samples.

- [Overview](#overview)
- [Colors](#colors)
- [Typography](#typography)
- [Layout](#layout)
- [Elevation & Depth](#elevation--depth)
- [Shapes](#shapes)
- [Components](#components)
- [Do's and Don'ts](#dos-and-donts)

## Overview

**Creative North Star: "Saved evidence, ready for conversation"**

Apple design language with ChatGPT-inspired restraint: familiar controls, compact navigation, and a generous reading pane. This records the finished Library and compatible app controls, not a redesign of conversation, settings, Graph, or Mind Map. Deferred graph surfaces keep their existing code and data.

The product's platform posture is adaptive; the shipping surface is SwiftUI on macOS 26+ only. No web, iOS, or Android implementation is implied. Native system typography and SF Symbols are intentional for navigation and controls. Document typography is adjustable in Appearance settings. The only raster images in the Library are locally captured source previews.

**Key Characteristics:**
- Semantic macOS surfaces and system light/dark appearance.
- Native sidebar, searchable list, and selectable Markdown reading.
- Quiet provenance and explicit handoff to Chat.

## Colors

### Primary

Use the system accent where no category tint applies. DocumentPreview
tints its actions and links with the primary category's AtlasPalette
ink. Native button styles determine their appearance; this is not a
fixed grayscale button system. Library and chat previews share summary
availability, the selected AI provider, progress, and cancellation. A
running page fetch owns its summary until it finishes; other library
work temporarily disables manual generation.

### Neutral

`Color(nsColor: .windowBackgroundColor)` owns the Library background.
`controlBackgroundColor` owns search, error notices, the composer, and
Markdown code blocks. Primary/secondary foreground styles and native
Divider retain macOS appearance behavior. Do not freeze these semantic
colors as screenshot hex values.

Sidebar labels use ink in light appearance and inverse ink when selected
or in dark appearance. LibrarySidebarLabelStyle dims icons to 0.72
opacity; filing codes use 0.5 opacity. Category rows use AtlasPalette
colors for their dots or folder icons. Selection remains native and
focus-dependent. Preview buttons use native disabled and pressed states,
not custom grayscale fills or borders.

**The Semantic Surface Rule.** Use native semantic surfaces for Library backgrounds; do not replace them with sampled screenshot colors.

## Typography

Use SwiftUI system text styles for app chrome. Appearance settings let
readers choose separate installed font families and 10–32pt sizes for
Notes and Sources. These preferences apply immediately to the document
preview and Markdown editor; they do not modify saved Markdown.
The frontmatter's title/body roles describe default Sources typography;
`note-body` describes default Notes typography.

- Notes default to Athelas at 14pt when installed, otherwise Georgia:
  personal notes, summaries, comparisons, and Writer documents. Existing
  custom choices stay intact. Sources default to the system font at 14pt:
  captured originals. Classification matches the Library's Notes/Sources
  scopes, not just the presence of a source URL.
- Document names use the chosen family, bold, scaled to 22pt at the
  default prose size. Markdown level-one headings use the chosen family,
  semibold, scaled to 17pt; lower headings use the prose size, semibold.
- List scope headings use `.title3.weight(.semibold)`. Content headings
  such as Summary and Full Text use the chosen reading family, semibold,
  scaled to 17pt at the default prose size.
- Row titles use `.body.weight(.medium)` and allow two lines.
- DocumentPreview prose uses its Notes or Sources preference.
  MarkdownPreview defaults to `.body` in callers that do not override it,
  including chat.
- The source/coverage line uses `.subheadline`; metadata cards and category
  chips use `.callout`. Row metadata and quiet hints use `.caption`.
- Counts use monospaced digits. Fenced code remains monospaced, scaled
  to the reading size in document previews and `.body` in chat.
- Font pickers list installed families, with a live preview and a reset
  for each group. Missing fonts fall back to the system font without
  erasing the saved choice. No bundled font is installed.

Paragraphs and quotes add four points of line spacing; bullet text adds
three. No uppercase eyebrow or tracking scale is installed.

The document body sits on a quiet reading surface with continuous 16pt
corners and 20pt padding. Its primary-color fill uses 0.035 opacity in
dark appearance and 0.025 in light appearance, with no border or shadow.
Its heading shares the reading font. Notes add a faint notebook dot grid:
1.2pt dots on a 20pt repeat, white at 0.10 opacity in dark appearance or
black at 0.08 in light. A cached image tile avoids work proportional to
note length. Sources stay plain; increased-contrast appearance hides the
decorative dots. The pattern ignores clicks and accessibility navigation.
Provenance, actions, and related items stay outside in system typography,
separating app UI from prose.

New summaries adapt to the substance of the captured source: an overview
alone when sufficient, usually three to six distinct takeaways for an
article, and up to ten under at most four meaningful headings for dense
material. These are not minimums. Both providers share a 600-word safety
ceiling, expanded evidence selection, and bounded evidence review;
unsupported takeaways are removed. Existing summaries are not rewritten.

## Layout

The hidden-title-bar window defaults to 1180 × 780pt with a 900 × 600pt
minimum. ContentView places a manually resizable sidebar beside the main
content. Library list/detail columns and the chat feed/saved-document
preview use HSplitView, not NavigationSplitView. Native split behavior
and explicit viewport constraints govern resizing.

| Region | Minimum | Ideal | Maximum |
| --- | ---: | ---: | ---: |
| Filing sidebar | 180pt | 220pt | 340pt (drag its edge; double-click resets) |
| Document list | 260pt | 330pt | 440pt |
| Capture list | 260pt | 330pt | 440pt |
| Reading detail | 320pt | Flexible | Flexible |
| Chat document preview | 320pt | 400pt | 520pt |
| Filing inspector | 300pt | 300pt | 300pt |

Reading content is leading-aligned and capped at 680pt, with 32pt
horizontal and 28pt vertical padding. Its width is
`min(680, max(0, viewportWidth - 64))`, so metadata and images cannot
enlarge a narrow scroll view. The chat split reserves room for its
preview: the feed minimum is `min(460, max(240, viewportWidth - 321))`
when the preview is open, otherwise 240pt.

Document/action stacks use 20pt spacing. List headers and handoff
controls use the list-inset token. Rows reserve 18pt for SF Symbols;
nested filing rows indent 10pt. Markdown tables scroll horizontally,
with 150pt cells and 16pt column gaps. Filing chips and their actions
wrap together rather than imposing a single-line minimum width. Chips
and actions share a text baseline on each wrapped row; the filing label
aligns with the first row's baseline.

Preview actions use ViewThatFits to replace text labels with SF Symbols
when needed, retaining accessibility labels and help. Search reload is
debounced by 250ms; results paginate in groups of 80. StatusText.swift
cross-fades status wording over 0.2s and animates numericText counts
with a 0.25s snappy transition. Document revision changes use a 0.25s
opacity transition. In-progress status uses the repeating variable-color
progress.indicator symbol on the text baseline.

## Elevation & Depth

Library uses semantic control surfaces, native selection, split
separators, and metadata cards rather than custom shadows. The info card
uses a quaternary background at 0.5 opacity. Native sheets and controls
retain system-provided depth; this is not a ban on system materials.

## Shapes

Search uses the frontmatter's 7pt curve. Row source images use 8pt
corners; detail source images and metadata cards use 12pt corners. The
composer uses a 24pt rounded rectangle and a one-point primary border at
0.1 opacity. Filing chips use Capsule. Native buttons, lists, sheets,
and selection retain system geometry; do not apply an invented shared
button radius. Code blocks use a rectangular control surface.

## Components

- **Navigation:** `.sidebar` list with Library/Filing sections, SF Symbols, and category codes. Filing rows carry their Atlas colour: a 7pt dot before the name, or the area row's folder icon tinted with it. Graph and Mind Map are not Library navigation destinations. Go › Back/Forward (⌘[ / ⌘]) and the mouse's back and forward buttons step through visited places: Chat or a scope, the Atlas region, and an opened item. Free zooming updates the current place rather than adding one.
- **Empty filing categories:** the map's Hide empty preference also dims
  empty sidebar homes in Chat and Automations. Both load and refresh the
  shared category snapshot without requiring a visit to the map first.
  Empty homes remain reachable.
- **Activity:** a sidebar destination with a native daily list and a
  read-only inspection pane. Day headers summarize matching activity;
  repeated edits and bulk operations expand into individual changes.
  Search, event-type filters, Today, and a date picker narrow the list.
  Date jumps use a native date field and Today/Yesterday shortcuts. Empty
  results fill the list column so controls stay above and the tracking
  note stays below; only the empty-state message is centered.
  The inspection pane reuses document reading and revision diffs. Its
  controls stack at narrow widths. Committed changes appear live; derived
  indexing and proposals do not. Earlier note history is labeled; fuller
  tracking starts at the migration date. Permanent deletion scrubs event
  titles, relationship labels, and revision pointers for both endpoints.
- **Search:** plain text field inside the rounded semantic control surface, magnifying glass, conditional clear action, ⌘F focus, and Escape to clear.
- **Document list:** `.inset` native list with multi-selection; title, kind/host, filing, and applicable coverage. Cache arrivals are observed so loaded rows replace placeholders.
- **Preview actions:** Captured Source, Open Original, Add to Chat, and
  Summarize appear in that order with the same quiet `.bordered` style.
  No action is arbitrarily primary. The action group uses
  `.controlSize(.large)` and 8pt spacing, with category tint inherited
  from the preview. More actions live in a borderless menu. Native styles
  own hover, press, focus, and disabled appearance; no custom button fill,
  radius, or brightness offset is specified.
- **Reading:** selectable native Markdown text with headings, lists, quotes, fenced code, and simple tables. No scripts or remote images load. Coverage, provider, filing, expandable capture limitations, and related source/artifact links accompany the text. Legacy summaries are classified by persisted Summary.md/Markdown/hash evidence, not filename alone; originals remain accessible through source relationships.
- **Source previews:** link captures show a top-aligned, fill-cropped
  still above the row title at 96pt tall, like a link preview's image. The
  still is the page's own wide share card (`og:image`/`twitter:image`, at
  least 600px wide and 1.3–2.6:1), else the hero cut from the screenshot
  (fixed and sticky overlays hidden, framed from the first heading and any
  lead image just above it, or by Vision attention saliency), else the top
  of the page. Corners are 8pt continuous with a 0.5pt quaternary hairline
  so white pages hold an edge on light surfaces; dark appearance dims it
  by 14%. The image is local capture evidence, not a remote load, and is
  hidden from assistive technologies because the title repeats it. Rows
  without a screenshot keep the text-only layout; no placeholder art.
  Detail previews use a viewport-constrained 170pt hero with 12pt corners,
  a 0.5pt separator border, and 0.9 image opacity in dark appearance.
- **Toolbar and settings:** chat and library share one toolbar shape:
  view-specific controls (the library's Map/List switcher) sit left of a
  trailing system-glass More menu (plain `ellipsis`) in both. Destructive
  or occasional actions such as Clear Conversation live in that menu.
  The app's Chat command menu owns Command-K (confirm clearing) and
  Command-Return (send), so they remain available while typing. Toolbar
  menu entries invoke the same actions without duplicate key equivalents.
  Command-K opens its confirmation dialog; it never clears immediately.
  The sidebar toggle and title share one stable navigation item to avoid
  native inter-item gaps. Sidebar animation is scoped below the toolbar;
  the navigation item does not animate. The entire titlebar uses the
  content area's solid background, with no material seam at the sidebar
  boundary. Native sidebar translucency and navigation rows stay below
  the titlebar.
  Settings is the standard Settings window (Gleanary › Settings…, ⌘,) with
  toolbar tabs (AI & accounts, Appearance, Capture, Filing, Writing),
  also linked from each More menu; no gear button in the window toolbar.
  Capture is a grouped form with two toggles, both on by default: summarize saved
  links, and save page previews (off fetches no screenshots, share images
  or video stills). Writing is a grouped form: Default style, a Details
  for picker, the preset's fields read-only with Copy to Custom, or the
  custom style's fields to edit. The settings window is 680 × 560pt with
  24pt content padding. AI controls are disabled during chat work; Stop
  Task remains available above them. The observable running state unlocks
  controls when the worker finishes.
- **Bookmark import:** File › Import Bookmarks… opens a native sheet: choose a browser/Raindrop HTML or Raindrop CSV export, review each folder's destination (existing category, a proposed new Johnny Decimal category, or unfiled) in an inset list with subfolders indented 16pt, then import with determinate progress. Imports read only export metadata; a page is fetched after its note stays open for one second.
- **Categorize Unfiled:** a sheet that runs suggestions in the background and groups them by category in collapsed disclosure rows with Accept All/Reject All, per-item accept/reject icons, an "Accept N Likely" bulk action with undo, and model-proposed new categories that must be created explicitly. The engine line states whether data leaves the Mac.
- **Chat reading position:** follow the bottom while within 40pt of the
  latest content. New messages, streamed text in an existing message, and
  late layout growth stay visible. User scrolling upward suspends
  following; returning to the bottom or choosing Latest messages resumes
  it. Layout growth alone must not be mistaken for user scrolling.
- **Chat research references:** generated results and their inputs have
  separate Summary/Comparison and Source/Sources groups. Result metadata
  says Generated by Researcher; each input retains its S1/S2 citation
  number and an Open website link when a valid HTTP(S) URL exists. Roles
  come from persisted artifact/task provenance, not titles. Display-only
  result titles omit Research:/Comparison: prefixes. The app-added source
  bibliography stays in the saved document but is replaced by these
  controls in chat; inline citations remain clickable. Other references
  retain the existing generic document presentation.
- **Research note titles:** new Researcher summaries and comparisons get
  concise, topic-focused titles generated from the verified result, not a
  copied source headline. Three to eight words is guidance; 12 words and
  80 characters are safety ceilings. The selected provider generates and
  separately evidence-checks the title before saving the note (two extra
  bounded model calls). Source names, content, and citation links stay
  unchanged; existing note titles are not rewritten.
- **Library agent changes:** with ChatGPT connected, multi-item requests such as retitling an inbox run a bounded tool loop that only proposes. Its reply carries one card (checklist symbol, a count per kind, "Proposed. Nothing changes until you apply.", and Review Changes…). The review sheet lists every change with a checkbox, grouped Titles, Summaries, New categories, Filing, Links, Moved links, Archive and New notes; old titles are struck through, new categories use the green New badge, and a filing into a proposed category selects with it. Applying rejects the unselected rest; the card then shows counts and Undo. The card sits under the task's last agent reply, whichever agent wrote it. A Writer refresh adds a Document revisions group first: the document's title and a line count ("12 lines added, 4 removed") over a line diff that is open by default, removed lines struck through on a red tint with a minus, added lines on a green tint with a plus, link targets hidden so citations read "(2)", and unchanged runs folded to a count.
- **Writer scope:** while a compose request waits for confirmation, its last agent reply carries a scope card (the same 10pt card surface): "Scope for this document" with "N of M checked" rolling as boxes change and Check All/Uncheck All, then a list of up to 240pt of checkbox rows (title, then filing and why it was gathered, after a comma) with an open-item button; possible strays carry an orange "Possibly off-topic" capsule and start unchecked. Below, a Style picker and an Allow general knowledge checkbox, a one-line limit note when too many are checked, and Cancel and Write Document (prominent). Stage progress under the composer keeps the stage still and rolls its count ("Extracting 12 of 37").
- **Library types:** a native All / Notes / Sources segmented picker
  appears above the map and list. One remembered selection follows the
  person across presentations and categories. Sources and Notes sidebar
  rows are shortcuts to that same filter. Filtering combines with the
  current category and search; empty results keep the controls and offer
  Show all types. Counts name notes or sources when narrowed. The map
  keeps the focused category even if filtering leaves it empty; the
  separate toggle explicitly names empty categories, not hidden items.
- **Atlas item cards:** sources, summaries, research notes, comparisons,
  and other authored items keep independent cards in All and Notes.
  Labels and symbols identify the saved item itself; summaries no longer
  disappear into source cards. Provenance and filing are unchanged.
- **Reader Mode:** an expand control at the reading section's upper right
  fills the content area without hiding the sidebar. Shift-Command-R
  enters; Exit Reader Mode or Escape restores the prior pane. Reader text
  uses the configured family at least 18pt, or 2pt above its normal size,
  capped at 32pt. This never changes saved appearance preferences. Reader
  Mode displays only the title and body, without metadata, actions, hero
  images, related items, or rounded paper containers. Notes reuse the
  notebook-dot texture across the reading surface; sources stay plain.
  Increased contrast hides the dots, as it does in normal notes. Entering
  and leaving crossfades over 200ms, with no spatial motion; Reduce Motion
  switches immediately. Essential capture warnings remain plain text.
  The reading measure stays bounded and centered, with left-aligned text;
  the sole surrounding control exits Reader Mode.
  Retained-source sheets offer the same reader for immutable extracted
  text. Normal detail panes also center their title, metadata, and paper
  together as one bounded column.
- **Category navigation:** keep the current cached rows mounted during a
  reload, then publish replacement rows and counts together. Do not clear
  the list or briefly substitute a loading layout between categories.
- **Automation history:** five completed runs per page, newest first,
  with a visible range and Newer/Older controls. Older pages load from the
  database, not a truncated recent-run cache. Paging preserves each
  automation's position and does not change its latest-run status, review,
  or undo behavior. History is not deleted to enforce the display limit.
- **Filing actions:** Change and Suggest share an explicit text baseline
  and stay together when wrapping after category chips.
- **Atlas thumbnails:** item tiles at least 88 × 54pt on screen show their page or video still as a duotone in the category colour, fading to the tile fill under the title. Stills load lazily for visible tiles only.
- **Automations:** a sidebar destination directly under Chat, above Library, since it's the agents' scheduled work rather than content (with a count of proposals waiting). The window title names the page, so the list opens with a one-line intro rather than a second heading. Laid out like the library: a list of automations, each with a coloured symbol tile, title, an on/off switch, a one-line status (schedule, last run or failure) and marks for running, a failed last run, and a count of proposals to review (the sidebar row repeats them), beside the selected one's detail: what it does and which agent runs it, a review button for its proposals, Schedule (plain text when there's only one choice, as for the weekly digest), Recheck items (for the link checker, cross-linker and unfiled filer), Last run with Run Now/Stop (while running, what it is doing, such as "Fetching 2 of 5: example.com", with the count rolling; the sidebar row repeats it), Next run, Due now (items waiting and about how many runs at the batch each run will take; new items always come first), Allowed to (phrased as what it does; whether you review first), then Options (items per run, with a line saying when a run is taking more to keep within the recheck interval; for the link checker, Dead links: Ask first or Archive automatically; for the weekly digest, a Write it up with the Writer switch, which also shows Allow ChatGPT and model calls per day) and History cards that are always open. Each run in History is one line that leads with what the run itself did, then what it found ("Proposed 2 changes for review, 2 unreachable", "Wrote 4 summaries", "Fetched 5 pages", "Saved 1 capture, 1 checking again", "Wrote a digest of 12 items", "Archived 2 dead links, 3 unreachable", "Nothing to change, 1 checking again") and opens, the latest open by default, to its items grouped by outcome (changed, proposed, moved, unreachable, need a login, checking again, skipped), each title opening the item (struck through and not a link once the item is gone, as after Undo), with Review or Undo beside its group (Undone in its place once undone) and a count of items that needed nothing.
- **Separators:** status lines and counts read as plain English: commas between clauses and counts ("Daily, ran 2 hours ago"; "2 titles and 1 filing"), a colon before a detail ("Saved full text without a summary: …"). The middle dot is kept for short metadata pairs such as a site and a kind or a name and a date, never to join clauses.
- **Archive:** a Library sidebar scope listing archived items.
  Archive/Unarchive sit in the item's More menu; an archived item's info
  card leads with an Archived row (date, reason, Unarchive). Archived items
  are left out of other scopes, the Atlas, search and Chat. A Linked card
  above Other notes from these sources lists linked items with the reason
  for each link.
- **Handoff:** pinned below list pagination; selected count, Clear, and Use
  in Chat. More than four selections disables handoff. Detail panes and
  retained-source sheets offer Add to Chat. It appends a removable Note
  or Source attachment, opens the existing conversation, and focuses the
  composer without replacing a draft or sending. Repeated additions do
  not duplicate context; a fifth attachment asks the person to remove
  one first. Source actions resolve the captured source's own saved item,
  not a generated note that cites it. Accepted messages move the submitted
  attachments out of the composer into clickable context chips inside
  the sent bubble. Failed submissions keep the draft and attachments;
  retries preserve a new draft. Sent context survives reopening, and
  deleted items show a neutral unavailable label. No second composer is
  introduced.
- **Note provenance:** Source or Sources links sit directly below the
  title and open the saved source in Library. They remain available for
  archived sources but omit deleted items. Other notes from these sources
  appear separately below the text; source items do not repeat there.
- **Recovery and mutation:** Captures lists what you saved yourself plus anything that failed; successful background bookmark fetches aren't listed, and the toolbar is its only heading. When summaries fail because of the AI provider itself (a model or plan no longer available, sign-in, usage limit), one window notice says so with Open Settings…, rather than the same error on every item; it clears when the provider or model changes. A failed capture someone asked for is named in the window notice (“Couldn't save …”, the reason, Show in Captures, Try Again); a background bookmark fetch that fails reports only on its item's Status row with Try Again, and isn't retried on every visit. Native empty/loading/error states, capture retry/stop actions, a filing inspector, and confirmed deletion. Each home chip in the info card shows a small remove button (xmark.circle.fill) at its corner on hover and has a right-click menu (Make Primary Home, Remove from …); removing the primary home promotes the lowest-coded one left, and the change is confirmed inline with Undo. Filing an item anywhere but Inbox takes it out of Inbox, whether from Change…, File Here, the library agent or a chat proposal; Undo puts it back. Beside Change… in the info card, a Suggest link (sparkles) asks the Librarian: "Asking the Librarian…" while it works, then an inline card with the suggested home as a chip (green New badge for a category it would create), its one-line reason, an "Also fits" list of other homes as outlined chips (each with Also File Here, which adds a secondary home and turns into Added with Undo, or "Already here"), File Here (or Create and File Here) and Dismiss; filing shows "Filed in …" with Undo. Nothing changes until File Here. Filing opens in a 300pt trailing column below the toolbar, built like the sidebar rather than with SwiftUI's `.inspector` (which claims the window toolbar): it follows the selection, lists categories by area with their colour dot and a search field, checks the primary home, marks other memberships "Also here", and applies a choice immediately. Note editing replaces the reading view in place (title in the reading view's title style, Markdown styled as it's typed by MarkdownEngine but saved character for character, Cancel/Save in a header bar) and stays put while the selection changes, so a draft is never dropped; new notes open there too. Errors remain readable and actionable rather than decorative status theater.

The sidecar's HTML/CSS samples are portable illustrations, not shipping
components or a substitute for native focus, selection, typography, and
accessibility behavior. Semantic native bindings are authoritative over
browser approximations.

## Do's and Don'ts

### Conversation composer follow-up

The user supplied ChatGPT's compact input as inspiration. The native composer now uses a 24pt rounded semantic control surface, a quiet one-point primary-color border at 0.1 opacity, 12pt horizontal and 9pt vertical padding, and 32pt attachment/send/stop controls. It expands from one to six lines rather than staying a fixed-height capsule. Task status, selected evidence and mention completion remain above it; privacy and keyboard hints remain below. These values apply to the composer only, not Library cards or every app control. No microphone or reasoning selector is implied.

### Do:
- **Do** preserve native semantic colors, text styles, SF Symbols, and keyboard-accessible controls.
- **Do** distinguish saved sources, generated summaries, and personal notes while keeping originals reachable.
- **Do** keep Library browsing and reading independent of inference.

### Don't:
- **Don't** replace this Library with decorative cards, branded status bars, or a visualization dashboard.
- **Don't** add a second composer or send a request automatically on handoff.
- **Don't** extend these Library decisions into unseen Graph, Mind Map, or settings redesigns.

Implementation evidence: Gleanary/ContentView.swift,
Gleanary/DocumentPreview.swift, Gleanary/ConversationView.swift,
Gleanary/GleanaryApp.swift, Gleanary/StatusText.swift, and
Gleanary/KnowledgeAtlasRenderer.swift.

The savedDocumentPreviewFitsNarrowPanes regression in
GleanaryTests/DocumentLibraryTests.swift checks preview widths of
320/400/520pt and chat splits of 560/680/960pt. ConversationTests checks
observation changes on task completion and cancellation. Synthetic
offscreen captures verify narrow layout, not interactive GUI or
VoiceOver certification. No user database was accessed for this
documentation.
