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

Apple design language with ChatGPT-inspired restraint: familiar controls,
compact navigation, and a generous reading pane. This records the finished
Library and compatible app controls. Library now includes a note-first
Graph and embedded note Connections. Mind Map and automatic concept
extraction retain their code and data but remain deferred.

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
- The identity/source/coverage line uses `.subheadline`; metadata cards
  and category chips use `.callout`. Source or Note appears at normal
  contrast and medium weight, with any subtype and host secondary. Row
  metadata and quiet hints use `.caption`.
- Chat replies, streamed drafts and the person's message text use the
  system font at 14pt, a step above the 13pt body style, since they are
  read as prose. Specialist activity, chips, captions and controls keep
  their own styles beneath them.
- Counts use monospaced digits. Fenced code remains monospaced, scaled
  to the reading size in document previews and to 14pt in chat replies.
- Font pickers list installed families, with a live preview and a reset
  for each group. Missing fonts fall back to the system font without
  erasing the saved choice. No bundled font is installed.

Paragraphs and quotes add four points of line spacing; bullet text adds
three. No uppercase eyebrow or tracking scale is installed.

In document previews the body sits directly on the window background,
below a divider, with no card around it. Its heading shares the reading
font. Reader Mode notes keep a faint notebook dot grid: 1.2pt dots on a
20pt repeat, white at 0.10 opacity in dark appearance or black at 0.08
in light. A cached image tile avoids work proportional to note length.
Sources stay plain; increased-contrast appearance hides the decorative
dots. The pattern ignores clicks and accessibility navigation.
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
| Chat document pane | 260pt | Flexible | Flexible |
| Chat beside a document | 280pt | 360pt | 480pt |
| Filing inspector | 300pt | 300pt | 300pt |

Reading content is leading-aligned and capped at 680pt, with 32pt
horizontal and 28pt vertical padding. Its width is
`min(680, max(0, viewportWidth - 64))`, so metadata and images cannot
enlarge a narrow scroll view. The reading measure is
`min(760, max(520, readingSize * 36))`, about 65–75 characters a line.
A saved document opened from Chat becomes
the main pane, with the feed and composer narrowed to a column on its
right; otherwise Chat fills the split with a 240pt minimum. The
document's bar offers Chat (back; Escape also closes), Open in Library
and a Focus toggle that hides the Chat column. Filing opens the Filing
inspector as a sheet. In the feed, the open document's reference chip
gains an accent outline and an Open label. While a document is open the
composer offers it with a dashed "About: …" chip and the placeholder "Ask
about this document…"; sending includes it as context for that message,
and the chip's remove button stops offering that document. Hovering a
reference chip for 700ms, pressing Space on it, or choosing Peek from
its menu shows a 360pt popover with the kind and host, title, first
paragraph in system text, filing, Add to Chat and Open (Return).

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
separators, and flat metadata rather than custom shadows. Under a
document's title, filing chips come first, then any Archived or Status
row, then a collapsed Details row titled with the saved date (Written by
or Summary, the full saved time, capture notes). Native sheets and controls
retain system-provided depth; this is not a ban on system materials.

## Shapes

Search uses the frontmatter's 7pt curve. Row source images use 8pt
corners; detail source images and metadata cards use 12pt corners. The
composer uses a 24pt rounded rectangle and a one-point primary border at
0.1 opacity. Filing chips use Capsule. Native buttons, lists, sheets,
and selection retain system geometry; do not apply an invented shared
button radius. Code blocks use a rectangular control surface.

## Components

- **Navigation:** `.sidebar` list with a selectable Library parent and
  collapsible Notes, Sources, and Unfiled filters. Expanded by default,
  it remembers its disclosure state. The label opens all items; only the
  chevron changes expansion. A collapsed active filter stays selected
  through Library and appears beside its label, without changing scope.
  Captures, Tasks, Activity, and Archive are peer destinations,
  separate from the collection filters. Filing retains its own section,
  SF Symbols, and category codes. Filing rows carry their Atlas colour:
  a 7pt dot before the name, or the area row's folder icon tinted with it.
  Graph is a Library presentation, not a separate sidebar destination;
  Mind Map navigation remains deferred. Go › Back/Forward (⌘[ / ⌘]) and
  the mouse's back and forward buttons step through visited places: Chat
  or a scope, the Atlas region, and an opened item. Free zooming updates
  the current place rather than adding one.
- **Empty filing categories:** the map's Hide empty preference also dims
  empty sidebar homes in Chat and Automations. Both load and refresh the
  shared category snapshot without requiring a visit to the map first.
  Empty homes remain reachable.
- **Note properties and templates:** optional semantic types do not
  replace Source/Note identity or filing. The Markdown editor keeps its
  body-first layout with a collapsible property editor. The reading pane
  exposes linked properties, backlinks, local checklists, and canonical
  tracked tasks in a native disclosure group. Pickers search saved notes
  locally and paginate; choosing a link never creates a placeholder note.
  More → Note templates opens stock and personal starters. Choosing one
  opens an unsaved draft; an existing draft requires discard confirmation.
  Dates and people are not copied silently by Save as template.
- **Tasks:** the window header names this destination, not the last
  Library filter. Do not repeat its heading inside the pane. Inbox,
  Today, Upcoming, All, and Completed are a native segmented filter;
  its group label is accessible but not shown beside the segments.
  Search and bounded result pages follow. Titles
  wrap and open a task editor; completion controls update the same record
  shown in notes. A quiet checkbox outline and borderless entry field sit
  above saved tasks. Return creates a task, clears the field, and retains
  keyboard focus; blank entries are never records. Today entries get a
  plan, not a deadline. Upcoming/Completed entries go to Inbox with a
  visible hint. Plan and Due have separate date controls. Only past due
  dates use the Overdue label and warning color. Project and origin links
  return to their saved notes. Use system controls, semantic surfaces,
  and the shared fading-dot loading indicator.
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
- **Knowledge graph:** a third Library presentation beside Map and List.
  Notes are the default nodes. The read-only SQLite projection combines
  applied links, Writer/research links, captured-source provenance, and
  saved explicit links. Scope, item type, and search filter both endpoints;
  archived/deleted items stay hidden. Optional Concepts includes only
  current, ready, quotation-backed analysis; viewing never starts
  extraction. Solid edges show links/provenance; extracted edges are
  dashed. Notes use filled page icons with three text lines; sources use
  outlined pages with a folded corner. Both the Library and embedded
  graph show the same legend. Shape and fill carry the distinction without
  relying on color; the accent outline remains reserved for selection.
  Document colors follow their own primary filing with the existing Map
  palette, falling back to the lowest-coded membership when none is
  primary. Unfiled documents and concepts/entities stay neutral. Filing
  metadata is fetched in one batch for visible documents, never per-node
  queries or inherited from linked sources or summaries. Secondary homes
  appear in the inspector and accessibility labels, not split-color
  glyphs. Filing-only refreshes preserve positions and camera; bounded
  drawing batches group by palette slot and Source/Note shape.
  Source/note labels also reach the canvas accessibility controls.
  Concepts and entities retain their existing shapes. The canvas uses native appearance,
  keyboard selection, pan, pinch/wheel zoom, fit controls, and a text
  connection inspector. Opening a note and changing graph focus
  participate in Back/Forward history.
  Show the Map/List/Graph toolbar picker only while its browsing surface
  is active. Hide it in full Map/Graph detail and editor views, Reader,
  Chat, Activity, Automations, and fixed-column Captures/Archived scopes.
  List keeps it while the list remains beside its detail. Returning from
  a full detail restores the picker without changing presentation or
  resetting the canvas.
  Note previews in Library and Chat show a local Connections canvas and
  text list, with Explore in Graph and direct/two-hop exploration in the
  full view. Embedded canvases have independent layout/selection state
  and no wheel zoom, so reading can still scroll. Empty notes explain
  that no connections exist. The full Library graph loads up to 10,000
  scoped items and every relationship between the loaded endpoints;
  visible/total counts expose the item boundary. Embedded graphs retain
  their small neighborhood limit. Load topology without quotations, then
  fetch current canonical evidence only for the inspected edge, in pages
  of 80 supporting entries with an explicit Load more action. Opening,
  searching, and inspecting never start inference or write graph data.
  The right inspector separates browsing from
  inspection: no selection shows a searchable native item list; selecting
  an item replaces it with grouped related notes, sources, and concepts.
  Each connection row names only the other endpoint. Selecting a row or
  canvas edge shows its rationale, with additional evidence collapsed.
  Directional labels read from the selected item's perspective. Headers
  stay above scrolling content. All items restores the mounted browser's
  search and scroll; Open note/source navigates to reading, while Focus in
  graph explicitly changes the neighborhood. Single-click selection runs
  independently of double-click opening; it never waits for a double-click
  timeout or a store query. Selection alone never changes scope or camera.
  The inspector is resizable and hideable; selecting a canvas item or edge
  reveals it again. The graph toolbar
  groups item filters and Concepts on the left, Arrange and the inspector
  toggle on the right, with search on its own second row. The inspector
  control stays monochrome: a filled right-pane symbol means open, an
  outlined sidebar symbol means closed. It names the action in its help
  and accessible label; no primary-color button fill marks its state. A
  quiet legend sits at the canvas's upper-left edge, outside the toolbar;
  labels avoid that area. Embedded Connections reuse the grouped
  neighbors and evidence flow without a global browser. Connection rows
  have 10pt internal padding on every edge, including inside hover fills;
  group headings align with their inset content.
  Arrange opens a native popover with a Compact–Spacious spacing slider
  and Reset. It adjusts link distance, repulsion, and minimum node
  clearance together, not graph membership or zoom. Previews debounce;
  releasing the slider settles the arrangement, honoring Reduce Motion.
  Each graph owns its spacing. Selection, scope, and camera remain intact;
  a selected node anchors a spacing-only layout. Fit remains explicit.
  Reset restores balanced spacing only. Labels try below, above, and
  beside nodes in priority order; labels that cannot fit without covering
  another label or node stay hidden. Selected labels get first choice.
  Large graphs reduce ordinary labels by zoom and screen-space budget;
  selected, hovered, and matched items get priority. Reuse resolved text,
  indexed world-space geometry, viewport culling, and bounded drawing
  batches instead of redrawing thousands of titles. Filled Note and
  outlined Source silhouettes remain distinct at low zoom; fine glyph
  details return as items grow. Fit supports large extents without the
  former 0.15 zoom floor. Pan/zoom, inspector resize, and same-scope
  topology refresh do not reset the camera. Layout reuses retained
  positions; large runs publish a seed and settled frame rather than
  invalidating the whole UI every six ticks. Reduce Motion skips animated
  settling. Library and embedded graph cameras and layouts stay separate.
  Within a window, each collection and item-type filter remembers its
  Map camera, focus, and selection, plus its Graph camera, node positions,
  selection, spacing, and inspector visibility. Returning reads current
  canonical data, discards missing selections, and only rearranges when
  topology changed or a layout was unfinished. Searches do not create
  additional collection memories. Graph neighborhood, concept, and depth
  controls also belong to each collection and survive presentation
  changes. Changing Map/List/Graph does not retarget the Map to a different
  collection. Viewport resizing preserves Map zoom
  and relative center; Fit and Reset remain explicit.
  The accessibility-only item list exposes at most 80 items per page,
  with explicit previous/next actions and range announcements. Every item
  remains reachable without materializing thousands of virtual buttons
  during pan/zoom. This does not paginate or truncate the rendered graph;
  the native inspector also retains its searchable item browser.
  Connection-based grouping and other grouping modes remain deferred.
- **Search:** plain text field inside the rounded semantic control surface, magnifying glass, conditional clear action, ⌘F focus, and Escape to clear.
- **Document identity:** Source uses the graph's outlined folded page;
  Note uses its filled page with text lines. The reading header, Library
  list/search rows, map cards, and graph inspector reuse these marks.
  Summaries remain notes, with Summary as a secondary subtype. Use 12pt
  gaps between the identity, subtype, and host groups, not middle dots or
  dividers. Other note subtypes follow the same pattern. Retained-text mode
  says Source even when its summary shares the saved item's ID. Type never depends on a URL,
  thumbnail, provider, or filing color. Keep the identity visible before
  secondary host metadata; do not add a pill, banner, or type palette.
- **Document list:** `.inset` native list with multi-selection; title,
  identity/host, filing, and applicable coverage. Cache arrivals are
  observed so loaded rows replace placeholders.
- **Preview actions:** Open summary appears first when a saved summary
  exists (a named Summaries menu for multiple notes). View source appears
  only when the retained text is not already being read. Open Original,
  Add to Chat, and Summarize follow with the same quiet `.bordered` style.
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
  view-specific controls (the library's Map/List/Graph switcher) sit left
  of a trailing system-glass More menu (plain `ellipsis`) in both. The Library
  switcher uses three equal-sized native toggle buttons, with no moving
  segmented-control separators. Choosing the active view keeps it active.
  Destructive or occasional actions such as Clear Conversation live in
  that menu.
  The app's Chat command menu owns Command-K (confirm clearing) and
  Command-Return (send), so they remain available while typing. Toolbar
  menu entries invoke the same actions without duplicate key equivalents.
  Command-K opens its confirmation dialog; it never clears immediately.
  Command-N is New Chat in Chat and New Note in Library. New Chat confirms
  before resetting the single conversation, cancelling its work, and
  discarding its unsent draft and attachments. Saved library items remain.
  It returns to a blank, focused composer; Clear Conversation continues to
  preserve the unsent draft. Neither shortcut inserts an agent command.
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
  or video stills). Writing has one Writing style picker: its selection
  is the default and owns the description and rules below. A short,
  left-aligned description precedes expandable Style rules. Preset rules
  use stacked labels and readable, leading-aligned values; custom rules
  use multiline editors. Customize copies and selects the preset, asking
  before replacing a saved custom style. Switching presets preserves that
  custom style. The settings window is 680 × 560pt with
  24pt content padding. AI controls are disabled during chat work; Stop
  Task remains available above them. The observable running state unlocks
  controls when the worker finishes.
- **Bookmark import:** File › Import Bookmarks… opens a native sheet: choose a browser/Raindrop HTML or Raindrop CSV export, review each folder's destination (existing category, a proposed new Johnny Decimal category, or unfiled) in an inset list with subfolders indented 16pt, then import with determinate progress. Imports read only export metadata; a page is fetched after its note stays open for one second.
- **Bulk filing suggestions:** Unfiled exposes Suggest filing directly in
  the Library toolbar. It opens the existing review workflow, also
  available through File/More > Categorize Unfiled. While suggestions run,
  the toolbar shows the shared working dot and Review filing. Opening the
  sheet does not start inference. Settings and saved filing review remain
  available during another library operation; disable only conflicting
  imports and new Suggest Homes requests, not the whole More menu.
  Explicit Suggest Homes runs bounded
  requests (up to 10 items locally or 40 with ChatGPT), saving suggestions
  after each batch and allowing Stop/resume with cached answers.
  The sheet groups suggestions by category in collapsed disclosure rows
  with Accept All/Reject All, per-item accept/reject icons, an Accept N
  Likely bulk action with undo, and proposed new categories that must be
  created explicitly. Nothing is filed until accepted. The engine line
  states whether data leaves the Mac.
- **Research-series filing:** publication commits before the Librarian
  checks the new notes and index against the existing filing scheme.
  Confident existing homes are applied as an undoable batch. Ambiguous
  placements and proposed new categories wait for review in one Organize
  notes sheet, scoped to this collection. Reused notes and cited sources
  keep their filing. The configured filing model sees all new members in
  one bounded classification call within the remaining series budget.
  A durable claim prevents automatic repeat calls. Cancellation, missing
  taxonomy, or inference failure cannot invalidate published notes or
  repeat research. Existing publications also expose the scoped follow-up.
- **Chat work indicator:** a 6pt foreground dot at the trailing edge of
  the Chat sidebar row appears only while its worker is running, including
  while browsing Library or other destinations. A slow native pulse stays
  inside a fixed 14pt footprint; the row and label do not move. Reduce
  Motion and inactive windows keep the dot steady. The row's accessible
  value says Working, without making the dot another navigation target.
  The composer's active-task status uses the same dot beside its progress
  text, not a spinner; the Send/Stop control keeps its existing behavior.
- **Chat reading position:** follow the bottom while within 40pt of the
  latest content. New messages, streamed text in an existing message, and
  late layout growth stay visible. User scrolling upward suspends
  following; returning to the bottom or choosing Latest messages resumes
  it. Layout growth alone must not be mistaken for user scrolling.
  Soft 22pt fades at the feed's top and bottom indicate offscreen content.
  Each edge follows its actual hidden distance, independently of the
  40pt auto-follow threshold, and disappears at that boundary. Short and
  empty feeds have neither fade. The overlays match the window surface,
  ignore interaction and accessibility, and leave the composer, preview,
  and Latest messages control untouched. Increased Contrast and Reduce
  Transparency disable them; no timed scroll-fade animation is added.
- **Chat turn hierarchy:** user messages remain trailing bubbles. Replies
  have no visible byline: the unboxed leading text opposite the bubbles
  identifies them, and each carries a VoiceOver-only "Gleanary" heading.
  Replies share the feed's text column with no extra inset, and turns
  are 32pt apart. Consecutive non-user
  messages for the same task form one presentation group; user messages,
  other tasks, and missing task IDs remain boundaries. Specialist updates
  sit in a native Activity disclosure, collapsed initially. Its whole
  label toggles it: a lone specialist reads as its work ("Researched",
  "Filed", "Found connections", "Drafted"), several are named, followed by
  "· N steps", which outranks names when space is short. While working,
  its summary uses the shared fading dot and actual task progress. A
  reply's references sit in one bordered card headed "Saved N items"
  (green check) when the task created or captured them, otherwise "N
  items"; each row shows kind symbol, title, kind and host, filing tag,
  an In Chat check and an Open state, with Space or the menu to peek.
  Bold or code spans that name a category take its filing ink. A failed
  or cancelled task shows its first sentence beside a warning symbol and
  a small Retry button; the rest of the message is the tooltip. The coordinating reply, unique
  saved-item links, proposal controls, Writer scope, filing review, and
  undo stay outside the disclosure. Per-message provenance and research
  reference groups remain inside activity. Older or directly addressed
  specialist conversations without a coordinating reply keep their last
  answer visible. Grouping never rewrites persisted messages, model
  history, evidence, or approval state. Failed/cancelled task details and
  Retry remain visible beneath the requesting user message.
- **Command palette:** Go › Command Palette… (⇧⌘P by default) floats a
  640pt panel 72pt below the window's top over a 25% black scrim; a
  click outside or Escape closes it, and Escape stops nothing else while
  it is open. Its field searches documents (title matches first, then
  text matches), categories, Go to places and commands, with matched
  letters bold and a word start or unbroken run ranked above scattered
  letters. An empty field shows Recent documents and Suggested commands;
  `>` limits results to commands and places, `#` to categories. Free
  text ends with Ask Gleanary "…", and a field of only links offers Save
  link, which queues in Chat. Rows show a symbol, title, subtitle, filing
  chip and shortcut; ↑↓ move, Return runs, ⌘Return opens a document
  beside Chat, and the footer names these keys. The list sizes to its
  results up to 400pt. Commands appear only where the window can run
  them. Menus, shortcuts and the palette all run commands from one list
  (`AppCommand`) by stable id.
- **Keyboard settings:** Settings › Keyboard lists every command by group
  with its shortcut. Clicking a shortcut records the next key press
  (Escape cancels); it needs ⌘, ⌥ or ⌃ unless it is a function key, and
  shortcuts macOS or text editing reserves are refused with the reason.
  A shortcut another command uses shows an orange banner with Cancel and
  Replace. Rows offer remove (×) and, once changed, reset; Settings and
  Stop Current Request show a lock. A filter field matches titles and
  shortcuts, and Restore Defaults resets all. Menus and the palette show
  the current bindings.
- **Chat queue:** sending while a request runs queues the new one instead
  of cancelling it, and a message that is only links queues one request
  per link. Queued bubbles dim to 0.7 opacity with a trailing "Queued ·
  n of N" caption and clock symbol. The composer card opens with a strip:
  the working agent, its progress and the request, plus an "N queued"
  pill that expands a numbered list with move earlier, move later and
  remove buttons. The composer placeholder becomes "Add to the queue, or
  ask something…" and Send adds to the queue; with an empty draft it is
  Stop, which ends only the current request, and Escape does the same.
  When a request finishes, fails or stops, the next starts. Requests
  still queued at quit wait after relaunch behind "Paused · N queued from
  your last session" with Clear and Resume; only the request that was
  running is marked interrupted. Removed requests keep their message and
  read "Removed from the queue".
- **Chat new topic:** New Topic (⌘N in Chat, the toolbar's More menu, or
  the palette) inserts a centered "New topic · when" capsule at 0.07
  primary fill, not a rule. Entries before the latest one fade to 0.6
  opacity. Nothing is deleted; Clear Conversation stays the way to wipe.
  After 6 hours without a message, the composer card is preceded by a
  capsule reading "Last message … ago · Start a new topic" with a dismiss
  button; it is driven by time alone, never by guessing the subject. New
  Topic waits while a request runs or waits in the queue, since those
  were asked with the earlier context.
- **Chat research references:** generated results and their inputs have
  separate Summary/Comparison and Source/Sources groups. Result metadata
  says Generated by Researcher; each input retains its S1/S2 citation
  number and an Open website link when a valid HTTP(S) URL exists. Roles
  come from persisted artifact/task provenance, not titles. Display-only
  result titles omit Research:/Comparison: prefixes. The app-added source
  bibliography stays in the saved document but is replaced by these
  controls in chat; inline citations remain clickable. Other references
  retain the existing generic document presentation.
- **Evidence-first research series:** new requests extract explicit user
  requirements and source policy before research. A provisional subject
  map guides evidence collection; it does not commit to note boundaries.
  Read saved notes first and prefer sufficient existing coverage. Gather
  public primary documentation for current research or remaining gaps.
  Retain pages and check exact quotations before allocating note purposes.
  Planning and feasibility review see quotation records and source
  metadata, not uncitable page continuations or generated fact summaries.
  Retrieval dates use ISO 8601 and do not imply publication dates.
  An independently reviewed plan assigns core evidence to one note,
  permits shared prerequisite context, and names neighboring exclusions.
  All writers and the series editor receive that same coverage contract.
  Notes can contain one to eight supported paragraphs without padding.
  Explicit requirements cannot be deferred; optional omissions appear in
  the index. A broad request is not an exhaustive vendor-release survey.
  One typed, versioned working state records phases, active plans, draft
  attempts, paragraph verdicts, editorial findings, and next actions.
  Immutable snapshots retain history; Retry does not reset counters or
  infer progress from unrelated recovery artifacts. Each note has three
  total draft attempts and at most two editorial revisions. Newly found
  problems in other notes do not consume a shared repair allowance.
  All calls retain the 96-call run budget. Search/download attempts are
  recorded before external work; unknown interrupted requests are not
  silently repeated. Library-only requests never browse. Optional
  model-proposed relationships can change; explicitly required endpoints
  cannot disappear. The app renders conceptual links rather than asking
  models to choose exact prose anchors. Publication validates a frozen
  plan, matching paragraph reviews, final editorial result, and source
  snapshot before committing the whole series atomically.
- **Legacy research-series recovery:** existing stopped runs keep their
  original engine, IDs, drafts, and recovery checkpoints. Their
  final-review failures name the rejected
  link rule or overlapping note instead of reporting generic Curator
  checks. Saved research, drafts, and failed reviews remain available.
  Each resume allows one repair pass and at most two Curator calls within
  the existing total call budget. Malformed links receive validation
  feedback; overlap reports identify only the new drafts to revise and
  their read-only comparison notes. Revisions must pass the same citation
  and quotation-support checks as initial drafts. Valid drafts and
  existing library notes stay unchanged. Original checkpoints remain
  immutable; verified revisions and the accepted draft/link bundle have
  their own checkpoints. Retry resumes verified revisions after an
  interruption. Relationships cannot disappear merely to pass repair.
  Publication still commits the complete validated series atomically, or
  nothing. Older Boolean-only overlap verdicts get a diagnostic review
  before targeted revision; no draft is guessed from a vague rejection.
  Initial draft failures name the note, the rejected citation or prose
  rule, and one-based paragraph numbers where available. Incomplete
  verifier output is not mistaken for an unsupported claim. Each current
  paragraph review distinguishes quotation support from topic relevance.
  Rejections include an exact substring of the failed paragraph and a
  bounded reason; approved paragraphs carry neither. Missing reasons,
  unanchored claims, wrong paragraph numbers, and contradictory approval
  cannot pass verification. Reasons remain untrusted critique, not new
  evidence. The Writer uses them to narrow or remove rejected claims,
  preserving supported paragraphs unless overlap repair requires changes.
  Draft feedback checkpoints retain reviews for the next bounded attempt
  and Retry. Evidence and overlap-comparison context must still match
  before a failed revision is reused. Retry keeps research and verified
  drafts; it does not repeat the original web research. Older Boolean-only
  feedback remains readable without fabricated explanations. Draft
  verification still allows at most two attempts per resume under the same
  total call budget; explanations require no additional inference calls.
- **Legacy targeted evidence recovery:** before rewriting an overlapping
  note, assess whether saved quotations can fulfill both its title and purpose
  with a distinct contribution. Relevant records may come from another
  extraction field; selecting them changes only this note's evidence
  scope. If insufficient, allow one targeted search per affected note for
  the entire run, reading at most two pages and extracting at most eight
  verified facts per page. Only a derived public keyword query reaches
  search, never the draft, PKMS excerpts, or reviewer prose. Library-only
  requests never search the web. Reassess the retrieved quotations; search
  summaries are not evidence. All assessment, search, extraction, drafting,
  and review calls share the original 96-call budget.
  Checkpoint search and download attempts before external work, so Retry
  cannot repeat an interrupted targeted request indefinitely. Keep pending
  research separate from approved evidence scopes. Restore an interrupted
  revision from its saved comparison and evidence. Existing sources,
  facts, verified drafts, and links stay intact; supplements have explicit
  per-topic source and record caps. Freeze the exact expanded evidence in
  the accepted publication bundle, including citation provenance and search
  counts. An exhausted search, unsupported revision, or repeated overlap
  after targeted research stops with an insufficient-evidence explanation;
  Retry does not restart that topic's search. Nothing is published
  partially.
- **Legacy evidence-driven scope adjustment:** if an automatically planned
  note still exceeds its saved evidence, propose one narrower supported scope
  and independently review it against the original user request. Never
  defer explicit requested coverage, modalities, exhaustive requirements,
  or relationships. Both checks share the original call budget. Keep
  IDs, fields, other verified drafts, source policies, and required links
  intact. Record removed optional coverage in the index's Remaining
  coverage section; reverify the affected draft against its revised title
  and purpose. Checkpoint proposals, refusals, approvals, scoped evidence,
  and verified revisions. Retry can restore an approved scope even from
  an older exhausted checkpoint, without repeating research. Freeze and
  validate the revised outline and disclosures in the accepted atomic
  publication bundle. A refused scope remains stopped.
- **Knowledge-entry voice:** new Writer documents and research-series
  notes default to reusable reference entries, not reports about the
  research. Use concise concept-focused titles, lead with the useful idea,
  and omit filler openings, obligatory conclusions, and research-process
  narration. Keep dates or versions when they define the subject's scope.
  Preserve citations, uncertainty, disagreements, and evidence limits.
  Both series outlining and prose receive the selected writing style;
  prose also receives the original request so explicit report, blog, or
  other format requests can override the default. Plain reflects this
  reference voice; other presets and saved custom styles stay intact.
  Existing notes are not rewritten, and captured-source summaries keep
  their separate summarization instructions.
- **Research note titles:** new Researcher summaries and comparisons get
  concise, topic-focused titles generated from the verified result, not a
  copied source headline. Three to eight words is guidance; 12 words and
  80 characters are safety ceilings. The selected provider generates and
  separately evidence-checks the title before saving the note (two extra
  bounded model calls). Source names, content, and citation links stay
  unchanged; existing note titles are not rewritten.
- **Model-led conversation:** normal chat uses model reasoning and tool
  results, not keyword routes or canned answers. Category, search, item,
  and review reads return data to the model before its final reply.
  Existing capture, research, note-saving, Writer, and linked-note-series
  workflows remain explicit publishing tools with their evidence and
  review boundaries intact. Only the UI can approve protected changes.
  Apple Intelligence uses guided tool turns with a smaller context limit;
  reaching that limit reports a scoped error instead of switching to a
  fixed planner. Neither a tool result nor a status update can approve a
  scope or reopen a finished task. Follow-ups retain access to saved
  result references and can retrieve older conversation or complete link
  lists instead of requesting repeated pastes. An explicit retain-sources
  request can capture up to 20 read, revision-bound links through the
  existing queue, including after web research in the same message.
  Citations, queued jobs, and retained Sources remain distinct. Capture
  does not apply filing proposals or rewrite the research artifact.
- **Library agent changes:** multi-item requests such as retitling an
  inbox run the same bounded tool loop and only propose. Its reply
  carries one card (checklist symbol, a count per kind, "Proposed.
  Nothing changes until you apply.", and Review Changes…). The review
  sheet lists every change with a checkbox, grouped Titles, Summaries,
  New categories, Filing, Links, Moved links, Archive and New notes; old
  titles are struck through, new categories use the green New badge, and
  a filing into a proposed category selects with it. Applying rejects
  the unselected rest; the card then shows counts and Undo. The card
  sits under the task's last agent reply, whichever agent wrote it. A
  Writer refresh adds a Document revisions group first: the document's
  title and a line count ("12 lines added, 4 removed") over a line diff
  that is open by default, removed lines struck through on a red tint
  with a minus, added lines on a green tint with a plus, link targets
  hidden so citations read "(2)", and unchanged runs folded to a count.
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
  the sent bubble. New messages never silently reattach references from
  earlier replies when the composer has no attachments. Conversation
  history remains available; retries retain their original attachments.
  Failed submissions keep the draft and attachments;
  retries preserve a new draft. Sent context survives reopening, and
  deleted items show a neutral unavailable label. No second composer is
  introduced.
- **Linked sources:** Notes in Library and Chat show a Linked sources
  section below the body and before Connections, outside Reader Mode.
  Detection parses saved Markdown locally, including reference links and
  bare web URLs, and excludes code, images, and internal/non-web links.
  Network or model work requires Add, Add all, or Summarize. The
  section shows five rows initially, with an explicit Show all action.
  Prefer descriptive bibliography titles over inline citation numbers or
  bare URLs when combining duplicate links; use the URL if no title exists.
  The remaining count sits beside the heading. A quiet + Add all action
  includes collapsed rows; its help and accessible label name the count.
  Borderless plus and retry actions have descriptive tooltips and
  accessible labels. Live capture progress sits below the host, using
  persisted phases rather than invented percentages. The shared fading
  working dot occupies the action slot while queuing or running; it stays
  steady with Reduce Motion. Saved sources share Open summary and View
  source controls with the main Library pane. Multiple summaries appear
  by name in a menu. View source reads retained text without fetching.
  Space separates rows; there are no rules or footer disclaimer.
  Capture uses the existing queue, safety checks, and settings.
  Duplicate active jobs share work atomically; durable request metadata
  retains each originating note across retries and restarts. Successful
  captures add ordinary saved references, not fabricated provenance, and
  never rewrite or refile the originating note. Removed links and deleted
  notes do not receive stale references. One failed addition does not
  discard other queued captures. A local job-identity index supports status
  checks and duplicate detection without repeatedly scanning queue history.
- **Note provenance:** Source or Sources links sit directly below the
  title and open the saved source in Library. They remain available for
  archived sources but omit deleted items. Other notes from these sources
  appear separately below the text; source items do not repeat there.
  Existing summaries have explicit Open summary links in linked-source
  rows, the main Library action bar, and the retained-source viewer.
  Multiple summaries show their names. Resolve them from canonical source
  provenance and summary classification, never from a title or URL guess.
  Include
  archived summaries but omit deleted notes, avoid self-links in note
  headers, and do not repeat featured summaries in the related-notes list.
  Opening a summary only navigates; it never starts generation.
  Do not add a separate Connected notes header. Ordinary references stay
  in Connections and do not imply a summary. Use as summary for this
  source opens a searchable, paged existing-note picker; the explicit
  association does not rewrite text or filing. A note can summarize more
  than one source. Explicit summary roles are per source; removing one
  keeps provenance and other summary associations. Existing authored and
  legacy summaries remain recognized without automatic reclassification.
  New manually requested summaries are separate editable notes, leaving
  captured originals and existing notes unchanged. Once a summary exists,
  hide the normal Summarize action. Create another summary belongs in the
  overflow menu and requires confirmation. Backend checks before model
  work and at publication prevent accidental duplicates. Keep the same
  relationships available in Connections.
  Atlas Open Source opens retained text in the main Library pane, not a
  sheet, including summary-first captures whose summary shares its ID.
  Open summary switches back to the saved note; showing retained text
  never rewrites it or exposes it to note editing. The optional Captured
  Source sheet uses rendered, selectable text by default, with Text and
  Original tabs, grouped reading/chat actions, and extraction notes below
  the reading area. Code alone is monospaced; raw Markdown is not the
  default reading presentation.
- **Reading hierarchy and links:** Linked sources and Connections use the
  same section-heading style with space above each section. Connections
  contains Graph and relationship-list subsections (Related notes,
  Sources, and other saved groups), with matching subsection headings;
  Related notes is not a separate peer of Connections. Arrange belongs
  beside the Graph subheading. Other reading-section headings use the
  same section style rather than a larger competing title.
  Rendered Markdown links use the native pointing-hand cursor only over
  linked characters. Linked paragraphs use selectable AppKit text with
  the reading font and inline formatting, without a web view; unlinked
  text keeps the existing renderer. Both web and internal note links use
  the app's URL action so saved-note navigation stays in the app.
- **Recovery and mutation:** Captures lists what you saved yourself plus anything that failed; successful background bookmark fetches aren't listed, and the toolbar is its only heading. When summaries fail because of the AI provider itself (a model or plan no longer available, sign-in, usage limit), one window notice says so with Open Settings…, rather than the same error on every item; it clears when the provider or model changes. A failed capture someone asked for is named in the window notice (“Couldn't save …”, the reason, Show in Captures, Try Again); a background bookmark fetch that fails reports only on its item's Status row with Try Again, and isn't retried on every visit. Native empty/loading/error states, capture retry/stop actions, a filing inspector, and confirmed deletion. Each home chip in the info card shows a small remove button (xmark.circle.fill) at its corner on hover and has a right-click menu (Make Primary Home, Remove from …); removing the primary home promotes the lowest-coded one left, and the change is confirmed inline with Undo. There is no Inbox category: an item with no home is unfiled, and Unfiled is where unsorted items wait. Beside Change… in the info card, a Suggest link (sparkles) asks the Librarian: "Asking the Librarian…" while it works, then an inline card with the suggested home as a chip (green New badge for a category it would create), its one-line reason, an "Also fits" list of other homes as outlined chips (each with Also File Here, which adds a secondary home and turns into Added with Undo, or "Already here"), File Here (or Create and File Here) and Dismiss; filing shows "Filed in …" with Undo. Nothing changes until File Here. Filing opens in a 300pt trailing column below the toolbar, built like the sidebar rather than with SwiftUI's `.inspector` (which claims the window toolbar): it follows the selection, lists categories by area with their colour dot and a search field, checks the primary home, marks other memberships "Also here", and applies a choice immediately. Note editing replaces the reading view in place (title in the reading view's title style, Markdown styled as it's typed by MarkdownEngine but saved character for character, Cancel/Save in a header bar) and stays put while the selection changes, so a draft is never dropped; new notes open there too. Errors remain readable and actionable rather than decorative status theater.

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
