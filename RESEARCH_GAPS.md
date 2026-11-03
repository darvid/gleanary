# Research gap detection: Stage 0 assessment

**Status:** Stage 0 (audit and plan) for
`gleanary-research-gap-detection-spec.md`. No feature code yet.

**Date:** 2026-11-03

## Bottom line

Gleanary already has most of the machinery the spec asks for. The
Writer's compose pipeline (SPEC §7.6) gathers a scope, waits for the
user to confirm it, extracts facts as verified quotes, and records
"not covered" for each requested field a source doesn't state. That
covers most of a coverage-gap detector. Search is already hybrid. The
work is mostly a new workflow on existing parts, plus one table.

About a third of the spec targets a multi-user hosted service. SPEC.md
lists that as a non-goal. Those parts map to "deleted and archived
items" and are otherwise skipped (see [Not applicable](#not-applicable)).

## How a request flows today

1. **Chat.** The chat model calls `start_workflow`
   (`ConversationWorkflows.swift`, one of `compose_document`,
   `research_sources`, `research_series`, …) through the bounded tool
   loop in `LibraryAgent.swift` (30 turns, 120 calls).
2. **Task.** The workflow becomes a `conversation_tasks` row. Its states
   are `queued`, `running`, `awaiting_user`, `succeeded`, `failed` and
   `cancelled`, and interrupted tasks recover as failed.
3. **Gather.** `AgentCoordinator.gather`
   (`AgentCoordinator+Writer.swift`) makes one structured brief call
   (`WriterBrief`: keywords, category codes, fields to extract). It
   builds candidates from `SearchEngine.search` plus category
   membership, and posts a scope card in `awaiting_user`.
4. **Extract.** `WriterPipeline.extract` chunks each item (24,000
   characters with ChatGPT, 3,000 on device, at most 4 chunks). It
   calls `extractFacts` and keeps a fact only if
   `FactRecord.verified` finds its quote in the chunk. Every unmet
   field becomes `.notCovered`. Records are cached in
   `extraction_records`, keyed by note, `contentHash` and field list.
5. **Write and save.** The output is validated (`WriterDocument.validate`
   rejects uncited blocks and unknown records), then saved in one
   transaction only while the task is still running.

## Capability map

| Spec capability | Observed implementation | Disposition |
| --- | --- | --- |
| Identity, permissions | Single local user. `notes.deletedAt` and `archivedAt`, plus permanent delete in `DocumentStore+Deletion.swift` (removes passages, captures and revisions; `extraction_records` cascades) | Reuse. Treat "authorized" as "not deleted or archived" |
| Ingestion, readiness | `ingestion_jobs`, `captures` (`extractorVersion`, `CapturedDocument.coverage` and `warnings`), `index_jobs` (`revision`, `lastError`) | Reuse. Add a readiness query per item |
| Source versions | `notes.revision` and `notes.contentHash`; `SourceVersion` in `Writer.swift` already pins hashes for Refresh | Reuse as the snapshot token |
| Passages, locators | `passages` (`noteID`, `ordinal`, `contentHash`) with `SourceCitation` (capture, block, page, section, time) | Reuse |
| Search | `SearchEngine.search`: FTS5 BM25 plus `NLEmbedding` sentence vectors, fused by RRF. It reports "keyword results only" when vectors are pending. It searches the whole library except deleted and archived items | Extend: optional item filter, and expose `notice` for limitations |
| Fact extraction | `FactRecord.verified` and `completed` (quote fidelity, `.notCovered`), cached per content hash | Reuse unchanged |
| Requirement origins | `ResearchSeries.Requirement` requires a `quote` found verbatim in the user request | Reuse the same rule for dimension origins |
| Provenance | `CapturedDocument.authors`, `published`, `sourceURL`. No publisher or origin-group data | Extend: origin group = source URL host, else unknown |
| Research scope | Johnny Decimal categories, item selection, Writer scope card | Reuse. Scope = categories and items confirmed on the card |
| Chat integration | `start_workflow` kinds, scope cards, task progress text, message `refs` | Extend: new `audit_research` kind |
| Jobs, cancellation | Conversation tasks, `Task.checkCancellation` in pipelines, durable index jobs | Reuse. Audits run as bounded user-initiated tasks |
| Scheduling | `AutomationEngine` with daily call budgets | Defer to Stage 4 |
| Model providers | `HostedInference` (ChatGPT), Apple on device. Writer caps on-device scope at 4 items | Reuse the Writer's provider split and caps |
| Feature controls | No feature-flag system | Add one Settings toggle, or ship hidden behind the workflow kind |
| Telemetry, cost | `conversation_events`, automation budgets. No analytics store | Reuse events. Add no telemetry |

## Proposed design

### Scope and dimensions (Stage 1)

- Add an `audit_research` workflow kind. The brief call reuses
  `WriterBrief` and adds:
  - **Proposed dimensions:** a label, answer criteria, and an optional
    origin quote from the request.
  - **Alternate terms:** per dimension.
- **The scope card gains a checklist of dimensions.** Each one starts
  checked only if its origin quote appears verbatim in the request
  (the `ResearchSeries` rule). Model-only dimensions start unchecked
  and say so. The card is the acceptance step; nothing runs until the
  user confirms it (AC-04).
- **New table `research_audits`:** a sibling of `writer_requests`,
  keyed by task ID. It stores the question, the accepted dimensions as
  JSON with their origins, the candidates and selection, the snapshot
  (`SourceVersion` list plus readiness per item), the status, and the
  findings as JSON. It is additive, so the previous app version is
  unaffected.

### Evaluation and counterevidence (Stage 2)

1. **Extract.** Run `WriterPipeline.extract` over the confirmed items,
   using the accepted dimensions as fields. The cache makes reruns
   cheap.
2. **Classify each dimension:**
   - **Supported:** a verified fact exists.
   - **Limited:** facts exist, but the semantic check says the
     criteria aren't fully met.
   - **Candidate gap:** every item returns `.notCovered`.
   - **Unknown:** see the readiness rules below.
3. **Counterevidence.** For each candidate gap, run
   `SearchEngine.search` three times: with the literal label, the
   alternate terms, and a plausible-answer phrasing. Run it over the
   whole searchable library, not just the selection. Extract from the
   top passages. A verified fact rejects the gap. If it was found
   outside the selection, the finding says where.
   - This also compensates for the 4-chunk extraction cap, because
     search reaches every passage.
4. **Readiness forces Unknown when:**
   - an item has a pending or failed `index_jobs` row;
   - the item's capture is metadata-only or has a coverage warning;
   - the search returned a "keyword results only" notice, unless
     lexical-only recall is accepted;
   - a required query or extraction call failed.
5. **Publish.** Only gaps that pass the check above are published, as
   a chat message with up to 3 finding cards. Each card has the
   dimension, the bounded wording, the reviewed and searchable counts,
   the snapshot time, its limitations, and Inspect / Dismiss buttons.
   Inspect opens the cited passages in the existing reader.

### Rest of the MVP (Stage 3)

- **Evidence imbalance:** at least 2 distinct supporting items share
  one source URL host, and no supporting item has an unknown host.
  Treat captures with the same `markdownHash` as one source.
- **Explicit questions:**
  - Candidates are lines ending in `?` in user-authored notes (not
    sources) within the scope. They're listed on the scope card for
    the user to accept, and each keeps its note and line as its
    origin.
  - An accepted question is evaluated as a dimension.
- **Workflow state:**
  - A `gap_dismissals` table keyed by finding fingerprint (scope
    categories, taxonomy, normalized dimension).
  - A dismissal is suppressed until a cited `contentHash` changes.
- **Re-running:** an audit re-run compares `SourceVersion` lists, the
  same way Refresh does, and marks earlier findings stale.

### Not applicable

- **Skipped:** tenants, sharing, cross-user caches, permission
  revocation mid-run, correlation IDs and analytics. There is one
  local user, and SPEC.md §1 rules out multi-user features.
- **Revocation maps to deletion or archiving.** Findings cite note IDs,
  so they resolve through the existing deleted and archived filters.
  Permanent deletion cascades `extraction_records`.
- **The spec's 9 logical operations collapse into:**
  - one workflow kind;
  - the scope-card confirm and cancel;
  - Dismiss and Inspect on the card.

  No new routes or services.

## Dependency order

1. Add an optional item filter to `SearchEngine.search` and
   `searchSnapshot`, and a per-item readiness query. Test both.
2. Add the `research_audits` migration, and extend `WriterBrief` with
   dimensions and alternate terms (a new struct if extending it breaks
   the Writer's schema).
3. Add the `audit_research` workflow, the scope card with the
   dimension checklist, and acceptance persistence.
4. Wire extraction, classification, counterevidence and the readiness
   rules into one pipeline with cancellation.
5. Add finding cards and Inspect. Fixtures for the 14 required
   scenarios in spec §11.1 use stubbed inference, as `WriterTests`
   does.
6. Stage 3: imbalance, explicit questions, dismissals, stale marking.

## Commands and baseline

- `mise run check`: swiftformat lint plus swiftlint strict.
- `swift test`: about 825 tests. Two failures already exist before
  this work:
  - `PageScreenshotTests.aSquareLogoIsNotAShareImage` always fails;
  - `NoteWorkspaceLayoutTests.nativeQuickEntrySaves…` is flaky.
- `mise run app:build` / `mise run dev`: build and open the signed app.
- **Not run for this audit:** the app itself. Launching it applies the
  pending `remove-inbox-v1` migration to the real library. Every
  behavior above was verified by reading code, not by running it.

## Risks

- **On-device scale:** the Writer caps on-device scope at 4 items. An
  audit is only useful with ChatGPT; on device it should say so, the
  same way the Writer does.
- **Semantic search is English-only** (`NLEmbedding`). For non-English
  items, the audit should report keyword-only search as a limitation.
- **The "Limited" state needs a semantic support call per dimension.**
  This is the main new model cost, so it should count against a
  per-run call budget, as the digest's budget does.
- **Brief schema change:** extending `WriterBrief` could change Writer
  prompts. A separate `AuditBrief` is the safer default.

## Decisions

Decided 2026-11-03:

- **Output:** chat finding cards only. No saved audit note for now.
- **Counterevidence scope:** the whole searchable library, not just
  the confirmed selection.
- **Evaluation:** the 14 fixture scenarios from spec §11.1, run as
  tests with stubbed inference. The 30-case held-out benchmark is
  not adopted.

## As built: Stages 1 and 2

Shipped 2026-11-03. Behavior is summarized in SPEC.md §7.9.

- **Code:**
  - `ResearchAudit.swift`: types, proposal validation and wording.
  - `ResearchAuditPipeline.swift`: read, disprove, classify.
  - `AgentCoordinator+ResearchAudit.swift`: gather and continue.
  - `DocumentStore+ResearchAudit.swift`: storage and evidence rules.
  - `ResearchAuditViews.swift`: scope and report cards.
  - Migration `research-audit-v1` adds `research_audits`.
- **Changes from the plan:**
  - **No search filter.** Counterevidence searches the whole library,
    so `SearchEngine` is unchanged.
  - **Readiness comes from what each item holds**, not
    `index_jobs`. Extraction reads an item's full text, so a pending
    embedding doesn't hide anything in the scope. A partly saved
    capture (abstract only, partial, bookmark) or a failed read makes
    absence Unknown.
  - **The plan has its own type.** `AuditProposal` replaces extending
    `WriterBrief`, so Writer prompts are unchanged.
  - **There's no Limited state yet.** Each criterion is atomic, so a
    partial answer shows as one criterion supported and another not
    found.
  - **The audit runs only from the chat tool.** It's started through
    `start_workflow`, not the planner's action list. Only hosted
    models are offered it: the on-device tool prompt has a
    14,000-character budget, and on-device models couldn't run an
    audit anyway.
- **Fixtures** (`ResearchAuditTests`, 15 tests): they cover 10 of the
  14 scenarios in spec §11.1:
  - answer hidden elsewhere;
  - genuine scoped absence;
  - partial answer;
  - missing ingestion (a partly saved capture, and an unreadable item);
  - failed retrieval (a failed hidden-answer read);
  - suggested question;
  - malicious source (fabricated quotes);
  - revoked source (deletion);
  - changed source;
  - irrelevant mention.

  Copied evidence, unknown provenance and explicit questions wait for
  Stage 3. The no-meaningful-change scenario waits for Stage 4.
