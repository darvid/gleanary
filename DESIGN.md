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
| Filing sidebar | 160pt | 190pt | 240pt |
| Document list | 260pt | 330pt | 440pt |
| Capture list | 260pt | 360pt | 480pt |
| Reading detail | 320pt | Flexible | Flexible |

Reading content is leading-aligned, capped at 640pt before its reading inset. Document/action stacks use the frontmatter rhythm; toolbar horizontal inset is the reading-stack token and vertical inset is standard. List header and footer share list-inset. Rows reserve 18pt for SF Symbols; nested filing rows indent 10pt. Tables scroll horizontally, with 150pt cells and 16pt column gaps.

Preview actions use `ViewThatFits` to replace text labels with SF Symbols when needed, retaining accessibility labels and help. Search reload is debounced by 250ms; results paginate in groups of 80. These are behavior values, not animation tokens.

## Elevation & Depth

Library adds no custom shadows, gradients, or raised card system. Native split separators, list selection, control surfaces, and small action borders supply hierarchy. Native sheets and controls retain platform-provided depth; this is not a ban on system materials.

## Shapes

Search and preview-action radii are the frontmatter's small, observed curves. Lists, selection, sheets, and other standard controls keep native geometry rather than adopting these radii globally. Code blocks use a rectangular semantic control surface.

## Components

- **Navigation:** `.sidebar` list with Library/Filing sections, SF Symbols, and category codes. Graph and Mind Map are not Library navigation destinations.
- **Search:** plain text field inside the rounded semantic control surface, magnifying glass, conditional clear action, ⌘F focus, and Escape to clear.
- **Document list:** `.inset` native list with multi-selection; title, kind/host, filing, and applicable coverage. Cache arrivals are observed so loaded rows replace placeholders.
- **Preview actions:** compact grayscale bordered buttons for captured source and original link; borderless small Edit/File actions. Press changes the grayscale fill. Enabled prominent actions elsewhere retain the system accent with brightness offsets of −0.12 at rest and −0.18 pressed. No custom hover or motion contract is implemented.
- **Reading:** selectable native Markdown text with headings, lists, quotes, fenced code, and simple tables. No scripts or remote images load. Coverage, provider, filing, expandable capture limitations, and related source/artifact links accompany the text. Legacy summaries are classified by persisted Summary.md/Markdown/hash evidence, not filename alone; originals remain accessible through source relationships.
- **Source previews:** link captures with a retained screenshot show it above the row title as a 96pt-tall, top-aligned crop (masthead and hero, like a link preview's image). Corners are 8pt continuous with a 0.5pt quaternary hairline so white pages hold an edge on light surfaces; dark appearance dims it by 14%. The image is local capture evidence, not a remote load, and is hidden from assistive technologies because the title repeats it. Rows without a screenshot keep the text-only layout; no placeholder art.
- **Toolbar and settings:** chat and library share one toolbar shape: view-specific controls (the library's Map/List switcher) sit left of a trailing system-glass More menu (plain `ellipsis`) in both. Destructive or occasional actions such as Clear Conversation live in that menu. Settings is the standard Settings window (Infactory › Settings…, ⌘,) with toolbar tabs, also linked from each More menu; no gear button in the window toolbar.
- **Bookmark import:** File › Import Bookmarks… opens a native sheet: choose a browser/Raindrop HTML or Raindrop CSV export, review each folder's destination (existing category, a proposed new Johnny Decimal category, or unfiled) in an inset list with subfolders indented 16pt, then import with determinate progress. Imports read only export metadata; a page is fetched after its note stays open for one second.
- **Categorize Unfiled:** a sheet that runs suggestions in the background and groups them by category in collapsed disclosure rows with Accept All/Reject All, per-item accept/reject icons, an "Accept N Likely" bulk action with undo, and model-proposed new categories that must be created explicitly. The engine line states whether data leaves the Mac.
- **Handoff:** pinned below list pagination; selected count, Clear, and Use in Chat. More than four selections disables handoff. Returning to conversation prepares evidence without automatically submitting a request; no second composer is introduced.
- **Recovery and mutation:** native empty/loading/error states, capture retry/stop actions, filing sheet, and confirmed deletion. Errors remain readable and actionable rather than decorative status theater.

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
