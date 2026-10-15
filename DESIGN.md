---
name: Infactory Native Library
description: Saved evidence, ready for conversation; a quiet native macOS Library.
colors:
  ink: "#000000"
  inverse-ink: "#ffffff"
  action-light: "rgb(94% 94% 94%)"
  action-light-pressed: "rgb(85% 85% 85%)"
  action-dark: "rgb(13% 13% 13%)"
  action-dark-pressed: "rgb(22% 22% 22%)"
  action-border-light: "rgb(56% 56% 56%)"
  action-border-dark: "rgb(42% 42% 42%)"
typography:
  title:
    fontFamily: "-apple-system"
    fontWeight: 600
  row-title:
    fontFamily: "-apple-system"
    fontWeight: 500
  body:
    fontFamily: "-apple-system"
  metadata:
    fontFamily: "-apple-system"
rounded:
  preview-action: "6pt"
  search: "7pt"
spacing:
  tight: "2pt"
  row-stack: "5pt"
  action-y: "6pt"
  row-y: "7pt"
  compact: "8pt"
  row-gap: "10pt"
  metadata-actions: "12pt"
  standard: "14pt"
  handoff-bottom: "16pt"
  list-inset: "18pt"
  reading-stack: "20pt"
  sheet-inset: "24pt"
  reading-inset: "28pt"
components:
  search:
    rounded: "{rounded.search}"
    padding: "{spacing.compact}"
  preview-action:
    rounded: "{rounded.preview-action}"
    padding: "6pt 10pt"
  preview-action-light:
    backgroundColor: "{colors.action-light}"
    textColor: "{colors.ink}"
  preview-action-dark:
    backgroundColor: "{colors.action-dark}"
    textColor: "{colors.inverse-ink}"
  document-row:
    typography: "{typography.row-title}"
    padding: "7pt 0"
---

# Design System: Infactory Native Library

## Overview

**Creative North Star: "Saved evidence, ready for conversation"**

Apple design language with ChatGPT-inspired restraint: familiar controls, compact navigation, and a generous reading pane. This records the finished Library and compatible app controls, not a redesign of conversation, settings, Graph, or Mind Map. Deferred graph surfaces keep their existing code and data.

The product's platform posture is adaptive; the shipping surface is SwiftUI on macOS 26+ only. No web, iOS, or Android implementation is implied. Native system typography and SF Symbols are intentional here, including titles. The only raster images in the Library are locally captured source previews.

**Key Characteristics:**
- Semantic macOS surfaces and system light/dark appearance.
- Native sidebar, searchable list, and selectable Markdown reading.
- Quiet provenance and explicit handoff to Chat.

## Colors

### Primary
System `Color.accentColor` remains available to compatible prominent preview actions; Library disables summary-generation actions. This is not a branded accent palette or a reason to recolor every action.

### Neutral
`Color(nsColor: .windowBackgroundColor)` owns the Library background. `controlBackgroundColor` owns search, error notices, and Markdown code blocks. Primary/secondary foreground styles and native `Divider` retain macOS appearance behavior; they are not frozen screenshot hex values. The sidecar records these native bindings because CSS color strings cannot faithfully encode NSColor semantics.

Sidebar labels use ink in light appearance, inverse ink when selected or in dark appearance; icons and filing codes use 0.72 opacity. Selection is neutral and native, with appearance and focus-dependent rendering. The explicit grayscale frontmatter colors belong to `PreviewActionStyle`, not the entire app's surfaces. Disabled action text uses 0.55 opacity; its border is one point.

**The Semantic Surface Rule.** Use native semantic surfaces for Library backgrounds; do not replace them with sampled screenshot colors.

## Typography

Use SwiftUI system text styles, not a fixed web type scale. Document titles and Markdown level-one headings use `.title2.weight(.semibold)`; list scope headings use `.title3.weight(.semibold)`; toolbar titles and lower Markdown headings use `.headline`. Row titles use `.body.weight(.medium)`. Reading uses `.body`; coverage and preview actions use `.callout`; filing, provenance, counts, and hints use `.caption`. Counts use monospaced digits and fenced code uses `.body.monospaced()`.

Paragraphs add four points of line spacing. No custom font, display face, uppercase eyebrow, or tracking scale is installed.

## Layout

The hidden-title-bar window defaults to 1180 × 780pt with a 900 × 600pt minimum. A compact toolbar sits above a balanced, resizable `NavigationSplitView`; native behavior governs resizing, not invented mobile breakpoints.

| Region | Minimum | Ideal | Maximum |
| --- | ---: | ---: | ---: |
| Filing sidebar | 180pt | 220pt | 340pt (drag its edge; double-click resets) |
| Document list | 260pt | 330pt | 440pt |
| Capture list | 260pt | 360pt | 480pt |
| Reading detail | 320pt | Flexible | Flexible |

Reading content is leading-aligned, capped at 640pt before its reading inset. Document/action stacks use the frontmatter rhythm; toolbar horizontal inset is the reading-stack token and vertical inset is standard. List header and footer share list-inset. Rows reserve 18pt for SF Symbols; nested filing rows indent 10pt. Tables scroll horizontally, with 150pt cells and 16pt column gaps.

Preview actions use `ViewThatFits` to replace text labels with SF Symbols when needed, retaining accessibility labels and help. Search reload is debounced by 250ms; results paginate in groups of 80. These are behavior values, not animation tokens. Text that changes on screen moves one way everywhere (`StatusText.swift`): status wording cross-fades over 0.2s, counts roll with `numericText`. In-progress status uses the animated `progress.indicator` symbol on the text baseline, not a spinner.

## Elevation & Depth

Library adds no custom shadows, gradients, or raised card system. Native split separators, list selection, control surfaces, and small action borders supply hierarchy. Native sheets and controls retain platform-provided depth; this is not a ban on system materials.

## Shapes

Search and preview-action radii are the frontmatter's small, observed curves. Lists, selection, sheets, and other standard controls keep native geometry rather than adopting these radii globally. Code blocks use a rectangular semantic control surface.

## Components

- **Navigation:** `.sidebar` list with Library/Filing sections, SF Symbols, and category codes. Filing rows carry their Atlas colour: a 7pt dot before the name, or the area row's folder icon tinted with it. Graph and Mind Map are not Library navigation destinations. Go › Back/Forward (⌘[ / ⌘]) and the mouse's back and forward buttons step through visited places: Chat or a scope, the Atlas region, and an opened item. Free zooming updates the current place rather than adding one.
- **Search:** plain text field inside the rounded semantic control surface, magnifying glass, conditional clear action, ⌘F focus, and Escape to clear.
- **Document list:** `.inset` native list with multi-selection; title, kind/host, filing, and applicable coverage. Cache arrivals are observed so loaded rows replace placeholders.
- **Preview actions:** compact grayscale bordered buttons for captured source and original link; borderless small Edit/File actions. Press changes the grayscale fill. Enabled prominent actions elsewhere retain the system accent with brightness offsets of −0.12 at rest and −0.18 pressed. No custom hover or motion contract is implemented.
- **Reading:** selectable native Markdown text with headings, lists, quotes, fenced code, and simple tables. No scripts or remote images load. Coverage, provider, filing, expandable capture limitations, and related source/artifact links accompany the text. Legacy summaries are classified by persisted Summary.md/Markdown/hash evidence, not filename alone; originals remain accessible through source relationships.
- **Source previews:** link captures show a 2:1 still above the row title as a 96pt-tall crop, like a link preview's image. The still is the page's own wide share card (`og:image`/`twitter:image`, at least 600px wide and 1.3–2.6:1), else the hero cut from the screenshot (fixed and sticky overlays hidden, framed from the first heading and any lead image just above it, or by Vision attention saliency), else the top of the page. Corners are 8pt continuous with a 0.5pt quaternary hairline so white pages hold an edge on light surfaces; dark appearance dims it by 14%. The image is local capture evidence, not a remote load, and is hidden from assistive technologies because the title repeats it. Rows without a screenshot keep the text-only layout; no placeholder art.
- **Toolbar and settings:** chat and library share one toolbar shape: view-specific controls (the library's Map/List switcher) sit left of a trailing system-glass More menu (plain `ellipsis`) in both. Destructive or occasional actions such as Clear Conversation live in that menu. Settings is the standard Settings window (Infactory › Settings…, ⌘,) with toolbar tabs (AI & accounts, Capture, Filing), also linked from each More menu; no gear button in the window toolbar. Capture is a grouped form with two toggles, both on by default: summarize saved links, and save page previews (off fetches no screenshots, share images or video stills).
- **Bookmark import:** File › Import Bookmarks… opens a native sheet: choose a browser/Raindrop HTML or Raindrop CSV export, review each folder's destination (existing category, a proposed new Johnny Decimal category, or unfiled) in an inset list with subfolders indented 16pt, then import with determinate progress. Imports read only export metadata; a page is fetched after its note stays open for one second.
- **Categorize Unfiled:** a sheet that runs suggestions in the background and groups them by category in collapsed disclosure rows with Accept All/Reject All, per-item accept/reject icons, an "Accept N Likely" bulk action with undo, and model-proposed new categories that must be created explicitly. The engine line states whether data leaves the Mac.
- **Library agent changes:** with ChatGPT connected, multi-item requests such as retitling an inbox run a bounded tool loop that only proposes. Its reply carries one card (checklist symbol, a count per kind, "Proposed. Nothing changes until you apply.", and Review Changes…). The review sheet lists every change with a checkbox, grouped Titles, Summaries, New categories, Filing, Links, Moved links, Archive and New notes; old titles are struck through, new categories use the green New badge, and a filing into a proposed category selects with it. Applying rejects the unselected rest; the card then shows counts and Undo.
- **Atlas thumbnails:** item tiles at least 88 × 54pt on screen show their page or video still as a duotone in the category colour, fading to the tile fill under the title. Stills load lazily for visible tiles only.
- **Automations:** a sidebar destination directly under Chat, above Library, since it's the agents' scheduled work rather than content (with a count of proposals waiting). The window title names the page, so the list opens with a one-line intro rather than a second heading. Laid out like the library: a list of automations, each with a coloured symbol tile, title, an on/off switch, a one-line status (schedule, last run or failure) and marks for running, a failed last run, and a count of proposals to review (the sidebar row repeats them), beside the selected one's detail: what it does and which agent runs it, a review button for its proposals, Schedule (plain text when there's only one choice, as for the weekly digest), Recheck items (for the link checker, cross-linker and unfiled filer), Last run with Run Now/Stop, Next run, Due now (items waiting and about how many runs at the batch each run will take; new items always come first), Allowed to (phrased as what it does; whether you review first), then Options (items per run, with a line saying when a run is taking more to keep within the recheck interval; for the link checker, Dead links: Ask first or Archive automatically) and History cards that are always open. Each run in History is one line that leads with what the run itself did, then what it found ("Proposed 2 changes for review, 2 unreachable", "Wrote 4 summaries", "Fetched 5 pages", "Saved 1 capture, 1 checking again", "Wrote a digest of 12 items", "Archived 2 dead links, 3 unreachable", "Nothing to change, 1 checking again") and opens, the latest open by default, to its items grouped by outcome (changed, proposed, moved, unreachable, need a login, checking again, skipped), each title opening the item, with Review or Undo beside its group and a count of items that needed nothing.
- **Separators:** status lines and counts read as plain English: commas between clauses and counts ("Daily, ran 2 hours ago"; "2 titles and 1 filing"), a colon before a detail ("Saved full text without a summary: …"). The middle dot is kept for short metadata pairs such as a site and a kind or a name and a date, never to join clauses.
- **Archive:** a Library sidebar scope listing archived items. Archive/Unarchive sit in the item's More menu; an archived item's info card leads with an Archived row (date, reason, Unarchive). Archived items are left out of other scopes, the Atlas, search and Chat. A Linked card above From the Same Sources lists linked items with the reason for each link.
- **Handoff:** pinned below list pagination; selected count, Clear, and Use in Chat. More than four selections disables handoff. Returning to conversation prepares evidence without automatically submitting a request; no second composer is introduced.
- **Recovery and mutation:** Captures lists what you saved yourself plus anything that failed; successful background bookmark fetches aren't listed, and the toolbar is its only heading. When summaries fail because of the AI provider itself (a model or plan no longer available, sign-in, usage limit), one window notice says so with Open Settings…, rather than the same error on every item; it clears when the provider or model changes. A failed capture someone asked for is named in the window notice (“Couldn't save …”, the reason, Show in Captures, Try Again); a background bookmark fetch that fails reports only on its item's Status row with Try Again, and isn't retried on every visit. Native empty/loading/error states, capture retry/stop actions, a filing inspector, and confirmed deletion. Filing opens in a 300pt trailing column below the toolbar, built like the sidebar rather than with SwiftUI's `.inspector` (which claims the window toolbar): it follows the selection, lists categories by area with their colour dot and a search field, checks the primary home, marks other memberships "Also here", and applies a choice immediately. Note editing replaces the reading view in place (title in the reading view's title style, Markdown styled as it's typed by MarkdownEngine but saved character for character, Cancel/Save in a header bar) and stays put while the selection changes, so a draft is never dropped; new notes open there too. Errors remain readable and actionable rather than decorative status theater.

The sidecar's HTML/CSS samples are portable illustrations, not shipping components or a substitute for native focus, selection, typography, and accessibility behavior.

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

Evidence: `Infactory/ContentView.swift`, `Infactory/DocumentPreview.swift`, `Infactory/InfactoryApp.swift`, and read-only supporting model/store code. Synthetic offscreen captures: `.build/library-redesign/infactory-library-{wide,narrow,light,source,summary}.png`. Independent fix review reports cache observation and legacy-summary classification resolved, with ship disposition at fix-review scope only; this is not external GUI or VoiceOver certification. No user database was accessed for this documentation.
