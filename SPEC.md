# Infact: Agent-Native Personal Knowledge System

**Status:** Implementation specification for an existing application  
**Last updated:** 2026-10-12  
**Primary audience:** Codex working in the Infact repository  
**Directive:** Build and validate a working vertical slice. Prefer running software and measured user experience over speculative abstractions.

---

## 0. Codex: Read This First

You are the lead engineer and product-minded implementer of **Infact**, an existing **Swift application backed by SQLite that already uses Apple Intelligence**. Your job is to evolve the real application into a compelling, local-first, agent-native second brain, **not** to bootstrap a replacement project.

**Operating instructions:**

1. **Inspect the repository first.** Identify supported Apple platforms, deployment targets, Swift/SwiftUI architecture, package/dependency choices, build instructions, existing SQLite schema and migrations, inference integration, ingestion pipeline, UI/navigation, tests, and any instructions in `AGENTS.md` or repository documentation. Those discoveries take precedence over proposed names and folder layouts in this spec.
2. **Preserve working code and user data.** Extend the current persistence model. Never drop existing tables or rewrite the database without a tested, reversible migration and a backup/recovery strategy. Preserve the current Apple Intelligence functionality.
3. **Execute, don't merely propose.** Implement the vertical slice, build it, run tests, fix regressions, and document results. Make incremental, reviewable changes. Use test doubles where network credentials, permissions, or device-only capabilities are unavailable.
4. **Make reasonable technical decisions autonomously.** Don't stop for stylistic choices, framework bikeshedding, speculative feature requests, or routine implementation details. Ask only when blocked by a true external dependency, unavailable authorization, materially ambiguous destructive action, or platform constraint that cannot be resolved from the repository.
5. **Avoid speculative infrastructure.** No PostgreSQL, graph database, server backend, Node/TypeScript runtime, microservices, Pi integration, agent marketplace, multi-room workspace, or elaborate ontology merely because those technologies might eventually be useful. Reuse existing dependencies and patterns when reasonable.
6. **Keep security and privacy real.** The SQLite database is the local source of truth. Treat ingested source text and model output as untrusted. Keep credentials in Keychain. Require review for destructive or consequential knowledge mutations. Explicitly communicate remote data sharing when enabling cloud inference.
7. **Do not claim features work without testing them.** Separate implementations, unit-tested paths, simulator/device verification, and OAuth end-to-end verification in the final report. Don't insert fake functionality into the production UI and present it as live.
8. **Prefer a polished, narrow experience over a broad but hollow prototype.** The goal is something a real user can ingest with, converse through, retrieve from, and meaningfully collaborate with.

### Required opening steps

- Read `AGENTS.md` and any nested guidance, `README`, build project and package manifests, relevant source files, migrations, and tests.
- Run the existing build and tests; record a baseline and pre-existing failures.
- Map the current source, artifact, category, inference, and navigation concepts to the ones below. **Adapt the spec to the codebase, not vice versa.**
- Write a concise `IMPLEMENTATION_NOTES.md` (or update an existing engineering notes file) with: existing architecture, migration strategy, selected vertical slice, build/test commands, decisions, deviations, and known limitations.
- Then begin implementation. Do not spend the entire session writing an architecture plan.

---

## 1. Product Thesis

**Infact is a local-first personal information factory.** It helps a person acquire, organize, find, evaluate, connect, and synthesize information through a **single persistent, shared conversation** with a small team of specialized agents.

The user should not need to know whether their request is technically ingestion, retrieval, metadata normalization, research, synthesis, or curation. They express an intent, optionally `@mention` a specialist, and Infact handles the underlying work.

### North-star experience

1. Open Infact and see one conversation, `#general`.
2. Paste an article or arXiv URL and ask Infact to save and summarize it.
3. The librarian records the canonical source and files it in the current Johnny Decimal scheme.
4. The researcher produces a useful, grounded summary, not just a generic restatement.
5. The curator notices relevant existing material and offers a meaningful connection or consolidation.
6. The agents communicate naturally, with visible contributions only when useful.
7. The user can interrupt, address any agent, inspect the source and generated artifacts, approve proposed changes, and retrieve the information later through ordinary language.
8. Restarting the app does not lose the conversation, source, artifacts, or associations.

### Product principles

- **Local-first:** knowledge and conversation are owned by the application, not a model provider.
- **One room:** a natural chat-first workspace, not four independent chatbots or a dashboard maze.
- **Agent teamwork without theater:** meaningful conversation, spontaneous relevant participation, visible handoffs, minimal robotic status chatter.
- **Bring existing knowledge:** preserve existing notes and SQLite content; support import/adaptation rather than forcing a new system.
- **Source-grounded output:** keep traceable links from generated material to the original source(s).
- **Simple structure now, extensible later:** sources, artifacts, categories and associations; do not invent an elaborate knowledge ontology.
- **Native and responsive:** SwiftUI UX, streaming feedback, accessible controls, keyboard friendliness, actionable states, cancellation.
- **Useful offline:** users can always browse/search saved content; on-device inference works where Apple's supported models are available.

### Explicit non-goals for MVP

- A full research graph or claim-level epistemic ontology.
- Fully autonomous unattended research loops or continuous web crawling.
- Perfect support for every PKM convention; **Johnny Decimal first**.
- A hosted multi-user SaaS, sync server, organizations, collaboration accounts, or multiple channels.
- Building a separate CLI, web app, or Pi-based runtime as the primary user interface.
- A universal plugin architecture, tool marketplace, generic workflow DSL, or agent voting system.
- A mandatory ChatGPT account or assumption that a ChatGPT subscription provides unrestricted API access.

---

## 2. Existing Application Is the Baseline

**Known:** Swift application, SQLite storage, Apple Intelligence inference, working product code exists.

**Unknown until repo inspection:** whether the target is macOS, iOS, or multiplatform; exact SQLite library/ORM; current source/artifact schema; extent of existing ingestion, search, UI and test coverage; whether user data is stored in app container, external vault, or both.

**Rule:** Do not assume it is a macOS app simply because the proposed UI resembles Slack. Respect actual target platforms and use conditional capabilities for platform-specific features.

After inspection, prepare an inventory:

| Area | Existing implementation | Reuse / extend / replace | Relevant files |
|---|---|---|---|
| App shell/navigation | Discover | Decide | Discover |
| Database and migrations | Discover | Prefer extend | Discover |
| Source ingestion | Discover | Prefer extend | Discover |
| Artifacts/notes | Discover | Prefer extend | Discover |
| Search | Discover | Prefer extend | Discover |
| Apple inference | Discover | Preserve and adapt | Discover |
| Tests | Discover | Expand | Discover |

Do not create duplicate models, tables, search indexes, or services before checking for existing equivalents.

---

## 3. MVP Experience: One Channel, Four Agents

### 3.1 Unified conversation

The principal interface is `#general`, a persistent chronological feed of messages from the **user** and these **four agents**:

| Agent | Handle | Responsibility | Domain authority |
|---|---|---|---|
| Assistant | `@assistant` | Interpret intent, facilitate, route, coordinate and ask for needed approvals | Task goals and user-facing clarity |
| Researcher | `@researcher` | Read, compare, analyze, summarize, synthesize information | Findings and evidence |
| Curator | `@curator` | Retrieve, connect, identify gaps/duplicates/conflicts and improve knowledge quality | Relevance and curation recommendations |
| Librarian | `@librarian` | Ingest, identify, normalize metadata, categorize, file, ensure structural integrity | Persistence and organization |

These are **task-scoped roles with real tools**, not permanently running LLM personas. Their differences must arise from their instructions, tools, responsibilities, and mutation authority.

### 3.2 Interaction rules

- A message with **no mention** goes to the assistant or an appropriate currently engaged agent chosen by the lightweight coordinator.
- An **explicit `@mention`** addresses that agent; don't unnecessarily route through assistant first.
- Allow mentioning multiple agents when useful; avoid indiscriminately running everyone.
- Agents can `@mention` one another or request a bounded task from another agent.
- Agents can volunteer a relevant contribution to an active task when grounded in new evidence or actionable context. They **must not** contribute to every user message just to perform their role.
- The user can address any agent at any point, ask follow-ups, redirect work, and interrupt an active task.
- A spontaneous suggestion is not equivalent to authorization to run an expensive external job or modify content.
- Agents can disagree, update views, and leave uncertainty unresolved. Don't force consensus by LLM voting.
- A conversation is a presentation layer over structured tasks and persisted objects. Chat prose is not an implicit database mutation.

### 3.3 Natural collaboration example

> **User:** @librarian save this paper and organize it: [arXiv URL]  
> **Librarian:** Added it under `31.04 Agent Architectures`. We already have a related paper on this topic.  
> **Curator:** The older paper covers memory retrieval; this one focuses on consolidation. They may be worth comparing.  
> **User:** @researcher compare them, especially their tradeoffs.  
> **Researcher:** I'll compare their assumptions and results.  
> *(Compact progress indicator: reading 2 sources)*  
> **Researcher:** The main difference is ... [specific citations and linked artifact].  
> **Librarian:** I have a proposed comparison note under `31.04`. [Review changes]  
> **User:** Keep the existing note as-is, but add the comparison.  
> **Librarian:** Saved the new comparison and linked both source records.

**Not acceptable:** canned inter-agent exchanges like “Delegating to X,” “Task acknowledged,” “Transfer complete,” or repeated summaries of one another's messages that add no value.

### 3.4 Suggested native UI

Use current app design language. The target experience should feel like a refined native combination of Slack/IRC conversational density and high-quality agent tooling, not a web chat clone.

- Single `#general` header, clear local/cloud inference status, accessible settings.
- Feed with compact author/avatar identity, time, rich Markdown, source and artifact references, and unobtrusive activity indicators.
- Composer with multiline support, send/cancel, paste URL/file support where platform permits, `@` completion with brief role descriptions, keyboard navigation and accessible labels.
- Per-task inline progress **only when meaningful**, with optional expansion for detailed tool events.
- Structured proposal cards for classification, new artifacts, cross-links, and edits. `Review`, `Apply`, `Reject`, or `Undo` as applicable.
- Selecting an artifact/source opens native detail/preview UI or the app's existing equivalent, without replacing the conversation.
- Respect system appearance, Dynamic Type, VoiceOver, reduced motion, narrow layouts, and platform human-interface conventions.
- Empty state teaches the product through examples, not a four-agent tutorial wall.
- Maintain conversational scroll position while streaming; do not constantly jump away when the user is reading history.
- Error, offline, cancellation, and unavailable-model states must be understandable and recoverable.

---

## 4. Lightweight Multi-Agent Execution

### 4.1 Architecture

Implement the smallest coordinator that supports explicit routing, bounded delegation, shared context, concurrency safety, cancellation, and persistable results.

```text
SwiftUI #general
  ├── Message composer / @mention resolver
  ├── Conversation and task event stream
  └── Source / artifact / proposal views
                  │
                  ▼
       AgentCoordinator (Swift actor or existing equivalent)
          ├── Assistant
          ├── Researcher
          ├── Curator
          └── Librarian
                  │
        ┌─────────┴──────────────┐
        ▼                        ▼
 InferenceProvider         Capability Tools
 Apple Foundation Models   Search / Ingest / Read
 Optional ChatGPT          Classify / Propose / Persist
        │                        │
        └──────────┬─────────────┘
                   ▼
            Existing SQLite
```

Keep the coordinator, tools and repository independent of SwiftUI views. Use Swift concurrency (`async/await`, actors or compatible existing patterns). Don't add an embedded server solely for agent routing.

### 4.2 Minimum execution contract

Represent work with straightforward, typed state and events, adapting names to the repository:

```text
Task: id, ownerAgent, initiatingMessageId, state, createdAt, updatedAt
States: queued | running | awaiting_user | succeeded | failed | cancelled
Events: started | progress | agent_message | delegated | proposal_created
        | completed | failed | cancelled
```

Minimum constraints:

- Each requested job has one owning task; child tasks may reference a parent.
- A delegated child has a clear outcome and budget. Bound depth (e.g. max 2) and total handoffs (e.g. max 4) initially; tune via tests.
- At most one active generation per non-reentrant Apple `LanguageModelSession`; don't issue concurrent calls to the same session.
- Never silently run unbounded agent-to-agent loops or repeated retrievals.
- Cancellation propagates to task children and network/model operations where supported.
- Persist meaningful messages, task states, and durable outcomes. Streaming token fragments and verbose traces need not all be stored permanently.
- Recover interrupted tasks after restart as interrupted/retryable rather than falsely marking them completed.
- Tool calls should return typed results and typed errors; validation occurs in application code, not only in prompts.

### 4.3 Context management

- Agent instances receive **task-scoped context**: relevant conversation excerpts, task instructions, retrieved source/artifact snippets, and links/IDs, not the entire vault.
- Keep each agent's role instructions concise and focused.
- Avoid mixing another agent's unverified draft into system-level instructions.
- Retrieve content on demand with existing SQLite search and provide precise provenance references.
- Apple on-device models have tighter context constraints: chunk/condense inputs, fail gracefully, and do not promise capabilities the active model lacks.
- Save durable records independent of ephemeral inference session histories.

### 4.4 Tool permissions

Propose a minimal shared, typed tool surface, mapping to existing services:

```text
sources.ingest(url_or_file)
sources.get(id)
sources.list_representations(id)
artifacts.create_draft(type, content, source_ids)
artifacts.get(id)
artifacts.search(query)
categories.list()
categories.suggest(entity_id)
knowledge.search(query)
knowledge.propose_relationship(left_id, right_id, type)
changes.preview(proposal_id)
changes.apply_approved(proposal_id)
```

Do not expose unrestricted SQL, shell, arbitrary file writes, or destructive migrations to model-generated tool calls. Enforce tools' permission checks outside the model.

Suggested default permission policy:

| Operation | Default |
|---|---|
| Read/search locally | Automatic |
| Generate a summary or draft artifact | Automatic |
| Ingest a user-submitted URL/file | Automatic after user action |
| Attach suggested categories to a newly ingested source | Automatic if reversible and visible |
| Link or modify existing content | Present proposal, require approval |
| Merge/move/delete existing records | Require explicit approval and rollback support |
| Start large unsolicited research or use cloud inference | Require user enablement / authorization |

---

## 5. Minimal Knowledge Model: Extend SQLite

**Do not replatform.** Use the existing SQLite layer and conventions (e.g. GRDB, SwiftData backed by SQLite, raw SQLite) rather than introducing a second persistence stack. Inspect existing schema first, then implement only missing concepts via versioned migrations.

### 5.1 Core concepts

- **Source:** the canonical identity and metadata of external or imported material. Examples: a web page, arXiv paper, YouTube video, imported PDF or Markdown document.
- **Representation:** original content and/or normalized accessible content, such as original PDF, HTML, transcript, extracted text, Markdown. May be represented using existing attachment/content storage; not necessarily a new table.
- **Artifact:** human- or AI-authored persistent output, including notes, summaries, transcripts if already treated that way, comparisons and research reports. It may relate to zero, one or many sources.
- **Category:** the Johnny Decimal organizational classification; one entity may have several category memberships, with an optional primary home.
- **Relationship:** lightweight cross-link between persisted entities/artifacts where required for actual user workflows.
- **Conversation / message / task / proposal:** state for conversational collaboration and reviewable changes.

Do **not** add separate `knowledge_entity`, `claim`, ontology, or graph tables until a concrete implemented workflow requires them. A mature evergreen note can be an artifact.

### 5.2 Associations and identity

- Give sources and artifacts stable identifiers; never rely on mutable URLs or display titles as primary keys.
- Canonicalize known identifiers such as arXiv IDs, DOI and YouTube video IDs when feasible, preserving user-submitted URLs.
- Prefer matching strong identifiers over fuzzy deduplication. If a probable duplicate is uncertain, propose a merge instead of silently discarding material.
- Support **many-to-many** source–artifact associations to enable multi-source syntheses.
- Support **many-to-many** entity–category membership. Distinguish `primary` from secondary memberships without duplicating source objects.
- Johnny Decimal is a stable **filing scheme**, not a full semantic ontology. Freeform tags and cross-links can coexist with numbered categories.
- Store metadata in existing typed columns plus JSON when useful; don't push every field into unvalidated JSON if it has important querying/integrity requirements.
- Track timestamps, provenance basics (`created_by`, source refs, model/provider when generated), and content version/revision data where practical.
- Use database foreign keys, unique constraints, indices and atomic transactions where appropriate.
- Handle SQLite migration rollback through database backup/recovery; don't falsely assume arbitrary schema downgrades are safe.

### 5.3 Search

- Reuse the current search implementation.
- Prefer SQLite **FTS5** for source titles, normalized source text, artifact text and searchable metadata when not already available.
- Ranking may initially combine FTS relevance, recency, and explicit category matches.
- Semantic/vector search is optional, only if already implemented or needed to pass a concrete retrieval evaluation. Don't block the MVP on an embedding database or vector extension.
- Every retrieved result must carry a stable ID and a UI-resolvable target.
- Never show fabricated citations or references to records that do not exist.

### 5.4 Source normalization

The first working vertical slice should include **URL ingestion plus one real, reliably supported text extraction path**. Reuse whatever ingestion formats already exist rather than reimplementing them.

Target coverage, as accessible and testable:

- Web article URL: fetch metadata/content, sanitize HTML, store normalized readable text.
- arXiv link/PDF: recognize stable arXiv identifier, capture public metadata, preserve the document, extract available text.
- Local PDF / Markdown: import via existing platform-safe picker, keep source identity and normalized text.
- YouTube: record canonical video URL/metadata and process an authorized/available transcript if obtainable; if unavailable, **save the source anyway** and report the limitation rather than inventing a transcript. Do not assume ChatGPT Sign in provides video transcription.
- Plain text typed in conversation: save as note/artifact when asked; don't force every message into the knowledge base.

Preserve originals (or reproducible URLs and retrieval metadata) and provenance. Normalize extraction output for downstream research. Avoid unnecessary remote services, undocumented scraping, or terms-violating access.

### 5.5 Johnny Decimal

- Expose and persist a simple configurable hierarchy of numbered areas/categories using the existing schema where possible.
- A source can have one canonical primary JD home plus other memberships as useful; artifacts can have their own categories independent of their originating sources.
- The librarian proposes category assignments based on existing taxonomy and content. Don't automatically create a forest of new categories for every topic.
- Editing or renaming categories preserves stable identifiers and references.
- When classification is ambiguous, surface a small number of clear options.
- Provide a basic way to browse or inspect assigned categories from source/artifact detail.

---

## 6. Apple Intelligence + Optional ChatGPT Inference

### 6.1 Provider-neutral application logic

Preserve the existing Apple Foundation Models integration. Introduce or adapt a narrow inference interface sufficient for agents to perform **streaming**, **structured responses**, **tool use if supported**, **cancellation**, **errors**, and **capability discovery**.

Illustrative shape (not prescribed exact Swift signatures):

```swift
protocol InferenceProvider: Sendable {
    var identifier: String { get }
    var capabilities: InferenceCapabilities { get }

    func run(
        request: InferenceRequest
    ) -> AsyncThrowingStream<InferenceEvent, Error>
}
```

Do not force providers into the lowest-common-denominator tool protocol if one has different constraints. A coordinator-level tool loop can normalize execution events when needed. Prefer the latest stable Apple APIs compatible with the application's deployment targets.

### 6.2 Apple provider

- It remains the **available-by-default local inference option** on supported hardware, OS versions and enabled Apple Intelligence configurations.
- Respect actual device/model availability and report unsupported states clearly. No misleading promise that it works on every Apple device.
- Use `LanguageModelSession`, guided generation and tool calling appropriately when available; check for existing implementation first.
- Handle small context budgets, session reentrancy and availability errors. For lengthy articles, chunk or use extraction-based operations rather than passing entire documents into a single constrained session.
- Keep non-inference actions (browse, search, edit manually) usable without model availability.

### 6.3 ChatGPT provider: verify the distribution model FIRST

As of 2026-10-12, OpenAI documents **Sign in with ChatGPT** with optional **ChatGPT-plan usage** for eligible **open-source, locally hosted applications**. Identity sign-in and permission to use a plan for inference are **separate permissions**. This does **not** provide access to ChatGPT conversation history and is **not** the same as unrestricted paid OpenAI API access.

**Before implementation:** determine whether this repository/product qualifies for the documented open-source local-client integration. If not, keep the provider behind a well-isolated feature boundary and document the supported alternative or approval path. Do not implement unofficial token extraction, reverse-engineered ChatGPT endpoints, or deceptive “Sign in with ChatGPT” UI.

For a qualifying open-source/local client, follow the current primary documentation rather than memorizing a flow from this spec:

- Overview: https://developers.openai.com/siwc/token-sharing-open-source
- Registration/sign-in: https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- Accounts/sessions/refresh: https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions
- Models and inference: https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- Limitations: https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
- UX guidelines: https://developers.openai.com/siwc/ui-ux-guidelines

**Documented integration details at writing time:**

- Native authentication requires an appropriate system-browser OAuth flow with state, OIDC nonce, PKCE, callback validation, and dynamic client registration for first sign-in. Follow the documented callback semantics and supported OS behavior; never embed credential entry in an app-controlled WebView.
- For first registration, docs describe `dynamic_agent_client`, a persisted `ext_agent_host_id`, and `agent_name_hint`; persist the **issued client ID** returned on registration for the authenticated account rather than reusing the special registration client ID for token exchange.
- Validate ID token, granted scopes, authenticated account and permissions. Plan usage is optional and must not be assumed from identity alone.
- Store tokens and account-specific identifiers securely in **Keychain**, not SQLite, plaintext preferences or logs. Serialize token refresh for rotating refresh tokens; support expiration, revocation, sign-out and account switching. Refresh tokens are rotated.
- When authorized, invoke the **documented public Responses API** (`https://api.openai.com/v1/responses`) with the user's OAuth access token. Do not use ChatGPT private backend endpoints.
- The current ChatGPT-plan HTTP flow requires `store: false` and `stream: true`, with relevant conversation history sent in the request `input`; do not rely on remotely stored state or `previous_response_id` over HTTP.
- **Not all Responses API tools and parameters are supported in the plan-usage preview.** Check the current limitations. Implement local tool calling/research extraction instead of depending on unavailable hosted tools or unsupported transcription/file uploads.
- Model catalog results do not necessarily prove entitlement: handle denied model access gracefully and don't hardcode availability.
- Track connection status and provider-specific failures separately from application task failures. If the user is offline, signed out or ineligible, preserve all local data and offer local actions/fallback when feasible.
- An OAuth end-to-end test needs a real eligible account and human authorization. Unit/integration tests must not depend on having a user's credentials in CI.

**Provider selection UX:** Default to the already working local provider when available; offer an optional `Connect ChatGPT` action with truthful permission/data-sharing language. Provide a user-visible selected provider and a clear indicator when source excerpts are sent to the cloud. Do not silently transmit the entire knowledge base or background-query cloud models merely because sign-in succeeded.

**Performance:** Do not assume ChatGPT is always lower-latency. Record first-token latency, total task duration, quality and failures per provider. Cloud models may improve complex synthesis even when local models handle short classification faster.

### 6.4 Provider policies and graceful degradation

- A simple global provider selection is sufficient for MVP. Optional per-agent overrides only if implementation is straightforward and genuinely useful.
- A cloud-only operation must explain how to proceed if not authenticated; do not silently fail or quietly substitute fabricated output.
- Keep inference-provider identities separate from agent identities. The researcher is still the researcher regardless of the model used.
- Model responses are suggestions/data until validated by deterministic application code and persisted through the repository layer.

---

## 7. Conversational Tools and Artifact Review

### 7.1 A complete first workflow

**Implement this complete journey first, with no mock back end in the shipping path:**

1. User pastes a supported public article/arXiv URL in `#general` and asks to ingest/summarize.
2. Assistant or mentioned librarian interprets the request and creates a tracked task.
3. Existing/new ingestion code creates or resolves a canonical source and normalized representation in SQLite.
4. Librarian selects an existing Johnny Decimal category or proposes a reversible assignment.
5. Researcher reads normalized content and produces a grounded summary artifact with source references.
6. Curator searches existing content; if genuinely related material is found, suggests a cross-link or improvement. Do not force a curator message when nothing useful was found.
7. Feed shows useful agent messages, compact progress and tappable source/artifact/proposal references.
8. User can ask a follow-up, explicitly `@mention` another agent and approve or reject proposed changes.
9. Restart app: conversation, source, artifact, category and any approved changes still exist and are discoverable.

### 7.2 Additional MVP workflows

- **Retrieval:** “@curator find the paper I saved about agent memory last week.” Return a real source card with title/metadata and a working open action.
- **Multi-source comparison:** “@researcher compare these two saved sources.” Save a synthesis artifact linked to **both** source IDs; ground statements where supported.
- **Manual note:** “@librarian save this thought under distributed systems.” Save a user-authored artifact without fabricating an external source.
- **Curation:** “@curator find overlapping notes.” Propose an edit/link for approval; do not silently rewrite existing material.
- **Interruption:** During an active research task, user redirects the researcher or cancels. UI and persisted task state reflect what actually happened.

### 7.3 Change proposals

A proposal should minimally include: target IDs, operation kind, human-readable rationale, a preview/diff of the concrete change, status (`pending`, `accepted`, `rejected`, `applied`), and a reversible operation when practical.

- Make proposals durable in SQLite when required for restart/review.
- Applying a proposal is idempotent and validates preconditions (record/version still matches the preview).
- Mark conflicting/stale proposals and request a refreshed preview; don't overwrite intervening user changes.
- Do not let an agent apply another agent's destructive proposal by “agreeing” in conversation without user approval.
- Clearly distinguish a proposed change from a persisted change in the channel.

---

## 8. Security, Privacy, Reliability

- Treat article text, transcripts, PDFs, imported Markdown and external metadata as **untrusted input**. Ignore embedded instructions attempting to alter agent responsibilities, retrieve secrets, exfiltrate data or override workflow policy.
- Perform tool-side authorization and input validation; prompts are not access controls.
- Limit outbound requests to intended services/resources. Mitigate SSRF-style URL fetch hazards where applicable, including private network and local resource URLs unless user explicitly selects a local file via OS picker.
- Avoid accidental credential leakage into logs, UI traces, crash reports, generated artifacts or LLM prompts.
- Preserve original imported files when appropriate and ensure normalized versions aren't the only surviving copy of user content.
- Use SQLite transactions, foreign keys and migrations; back up user data before risky bulk transformations.
- For any existing vault import, never overwrite source files in place without explicit user approval, an inspectable plan and recoverable backup.
- Make cancel/retry safe: no duplicate artifacts or partially applied destructive changes on retry.
- Use structured logs with task IDs and redaction. Developer diagnostics may contain timings and operation names, not private note contents by default.
- Ensure remote inference consent covers the specific content actually sent. Expose a simple local-only mode.

---

## 9. Implementation Sequence and Definition of Done

Implement **in order of user-visible value**, adjusting sequence when repo architecture offers an obviously simpler path. Commit coherent steps where permitted; never make unrelated broad refactors as a prerequisite.

### Phase 0 — Discover and preserve

**Build:** inventory repository; run baseline build/tests; inspect data model, ingestion and Apple inference; document reality and migration plan.  
**Done when:** baseline results and source/schema map are recorded, and no unreviewed destructive data change is required.

### Phase 1 — Chat as the primary workflow

**Build:** persistent `#general`, composer, messages, mentions, conversation history, message authors, streaming status, minimal task/event persistence. Route explicit mentions even if initially the agents are single-agent executions.  
**Done when:** all four roles are addressable, messages persist across restart, and user can view/cancel an active task.

### Phase 2 — Make the knowledge flow real

**Build:** a supported URL ingestion path using existing services, canonical source persistence, normalization, librarian JD filing, researcher-generated summary artifact, and source/artifact detail references. Use Apple inference where available; if device testing is unavailable, exercise provider via a deterministic test double while accurately reporting hardware limits.  
**Done when:** ingest → categorize → summarize → save → search/retrieve → restart works end to end with a real source.

### Phase 3 — Meaningful agent teamwork

**Build:** lightweight coordinator, bounded cross-agent delegation, context retrieval, curator lookup/relevance, a useful agent-to-agent exchange when justified, conversational follow-up and user interruption.  
**Done when:** user can independently address researcher and librarian, a curator contribution surfaces only on relevant matches, and conversations remain readable rather than stuffed with procedural chatter.

### Phase 4 — Reviewable knowledge changes

**Build:** curation/link proposals, preview/apply/reject, optimistic concurrency/precondition checks, and revision or undo capability using existing persistence patterns.  
**Done when:** an agent suggests a meaningful edit to existing information and user can inspect, accept or reject it without data loss.

### Phase 5 — Optional ChatGPT

**Build:** verified provider boundary, authentication and permission handling **only where the supported distribution route applies**, streamed inference, Keychain storage, provider choice and graceful fallback.  
**Done when:** eligible authenticated user can complete a real task using authorized ChatGPT-plan inference; missing eligibility/consent produces a correct local experience. Otherwise isolate the unfinished integration and clearly document the external blocker without breaking the rest of the MVP.

### Phase 6 — Polish and evaluate

**Build:** native interaction polish, loading/error/offline states, keyboard and accessibility support, diagnostics, tests and representative scripted demo scenarios.  
**Done when:** a real user can perform core scenarios without debugging tools, and the app builds/tests on the supported targets.

**Sequencing note:** If ChatGPT availability is critical to demonstrating research quality, prove a minimal auth + streaming spike sooner, but do not let pending external consent stall the local-first product.

---

## 10. Test Plan: Build Trust in the Vertical Slice

Prefer deterministic unit tests and integration tests with test databases and model/network fixtures; add UI tests for critical interactions when tooling permits.

### Minimum automated test categories

1. **Database and migrations:** existing sample DB upgrades without data loss; foreign keys and associations hold; app can reopen and retrieve records; rollback/backup recovery path is documented and tested where applicable.
2. **Source identity/dedup:** equivalent arXiv links resolve to same source; distinct version/content cases aren't silently collapsed; duplicate submissions don't create redundant artifacts unexpectedly.
3. **Classification:** source supports primary JD category and secondary memberships; artifact can differ from parent source; invalid category codes are rejected according to selected policy.
4. **Ingestion/extraction:** valid URL, malformed URL, network timeout, blocked URL, empty content, missing YouTube transcript, document parsing failure, and recoverable retries.
5. **Inference providers:** streaming delivery, cancellation, structured response validation, timeouts, error propagation, provider availability, fallback/selection and secret redaction.
6. **Agent routing:** direct `@mentions`, unmentioned default, irrelevant-agent suppression, handoff budget, no infinite delegation, failure of a child task, cancellation while another agent speaks.
7. **Persistence and UX state:** chat/references/task status across restart; stale proposal cannot clobber a changed artifact; reject and accepted changes are accurately reflected.
8. **Security:** prompt injection in an ingested article cannot execute prohibited tools, request private local files or turn a draft into a committed destructive operation.

### Live smoke scenarios

Run on supported target platform(s), using an actual local database seeded with safe non-sensitive test content:

- **S1:** Ingest a real public article; verify title, source URL, normalized text and Johnny Decimal category persist.
- **S2:** Ask the researcher for a summary; save an artifact with an actual link to the source.
- **S3:** Add a related second source; request comparison; verify one artifact linked to two sources.
- **S4:** Ask curator for related existing content; see a genuine retrieval result or candid “none found,” never invented notes.
- **S5:** User addresses librarian during active work; conversation remains coherent and state does not corrupt.
- **S6:** A proposed edit is reviewed and declined, leaving the original unchanged; separately approve another and verify persistence.
- **S7:** Disconnect network/disable cloud; saved information remains accessible, and local inference availability is represented accurately.
- **S8:** Restart application; review prior messages, sources, artifacts, categories and recent task outcome.
- **S9:** Where supported and authorized, sign in with ChatGPT, complete one streamed inference request, then revoke/sign out and verify safe fallback.

### Product-level evaluation signals

Instrument unobtrusively and locally first:

- Time from paste/request to saved, useful artifact.
- First visible response latency and total task duration.
- Ingestion and retrieval success rate.
- User corrections per task, especially wrong classification and irrelevant synthesis.
- Agent contributions judged useful vs. redundant.
- Proposal acceptance/rejection and unintended mutation rate.
- Return usage: can a user find and reuse something they saved earlier?
- Local vs cloud task quality and latency on the same representative fixture set.

**Critical hypothesis to test:** Does collaborative agent behavior make real work more effective than a single assistant using the same tools? Design the architecture so that simple single-agent comparisons are possible; don't bake in obligatory four-agent participation.

---

## 11. Acceptance Criteria: What “Shippable Prototype” Means

The MVP is acceptable when all statements below are true (or clearly documented as externally blocked):

- [ ] Existing Swift app and database still work; current user records and Apple Intelligence functionality are preserved.
- [ ] A persistent, polished, accessible native `#general` conversation exists.
- [ ] All four specialists have meaningfully distinct responsibilities and support explicit `@mentions`.
- [ ] A user can ingest at least one real URL-based source and inspect stored canonical metadata/content.
- [ ] A librarian can assign a valid Johnny Decimal category using real persisted category data.
- [ ] A researcher can generate and persist a grounded summary linked to the ingested source.
- [ ] A curator can search actual saved material and offer at least one relevant, non-fabricated discovery/cross-link suggestion.
- [ ] Agents can hand off tasks naturally without obligatory rote dialogue, infinite loops or UI lockups.
- [ ] A user can interrupt or redirect work and review meaningful, proposed mutations.
- [ ] Source and artifact relationships, messages and outcomes survive restart.
- [ ] Basic full-text or existing equivalent search actually retrieves saved content.
- [ ] The app handles unavailable models, offline operation, malformed source input and task failures without data loss.
- [ ] Sensitive tokens are never stored in SQLite or printed in logs.
- [ ] Optional ChatGPT authorization is implemented only through a currently supported route with explicit permission and truthful UX; otherwise clearly isolated and reported as a blocker.
- [ ] Meaningful automated tests exist; project builds and tests pass on available supported targets or environmental blockers are precisely described.
- [ ] No placeholder UI, mock retrieval hits or invented citations are represented as working production features.

---

## 12. Engineering Quality Bar

- Use idiomatic modern Swift, Swift concurrency, existing project conventions and native SwiftUI components.
- Prefer clear type boundaries, actors for mutable shared state, and small dependency-injected services. Avoid global mutable agent state or singleton-driven business logic when practical.
- Maintain clean error propagation and cancellation, especially between model streaming, ingestion and DB writes.
- Avoid duplicated retrieval/business rules in per-agent prompts. Tools and persistence services own deterministic invariants.
- Keep prompts versioned/discoverable as code or resources and test their outputs with fixtures where possible.
- Build reversible persistence changes and idempotent workflows; avoid replacing production data to make the demonstration easier.
- No gratuitous third-party packages. Use built-in Apple APIs and current project libraries where they suffice.
- UI needs to be a pleasure to use: consistent type scale, whitespace, small feedback animations where appropriate, discoverable actions, no crowded dashboards or excessive decorative output.
- Add useful user-facing errors and developer diagnostics rather than swallowing exceptions.
- Respect platform permission requirements, sandboxing, ATS, URL loading and files access.
- Documentation should reflect what actually shipped, not a wish list.

---

## 13. Handoff Format for Codex

After each substantial milestone, maintain a short status in `IMPLEMENTATION_NOTES.md` with completed features, migrations, tests, and remaining gaps. When finishing the execution run, report:

1. **What actually changed** (screens, workflows, runtime services, models, migrations).
2. **Where it lives** (paths to central source files, not giant pasted code dumps).
3. **What was verified** (exact build/test commands and outcomes; device/manual checks separately).
4. **What is incomplete** (especially device-dependent Apple Intelligence testing and ChatGPT OAuth consent/eligibility).
5. **How to run and demo** a full ingestion → discussion → artifact → retrieval flow.
6. **Next three product improvements** based on real observed friction rather than speculative infrastructure.

Do not stop once the chat UI renders. A successful run requires the actual knowledge operations behind the interface. If external authentication or hardware availability blocks the cloud path, finish the local-first flow and leave a clean seam and precise integration instructions.

---

## 14. Official Reference Pointers (Verify Before Implementing)

The following references guide integration. They do not supersede current SDK documentation, app distribution policy, the actual repository, or the tests.

- [Apple Foundation Models: LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- [Apple Foundation Models: generating content and tasks](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Apple Foundation Models: tool calling](https://developer.apple.com/documentation/foundationmodels/tool)
- [OpenAI: Sign in with ChatGPT, open-source local tools](https://developers.openai.com/siwc/token-sharing-open-source)
- [OpenAI: registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [OpenAI: models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [OpenAI: current preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [OpenAI: account sessions and token refresh](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)

---

## Final Instruction

**Go build the smallest real Infact experience that demonstrates the promise:** one conversation, four useful specialists, genuine source ingestion, Johnny Decimal filing, source-grounded synthesis, local persistence, meaningful collaboration, and retrieval. Preserve the working Swift/SQLite/Apple Intelligence application. Make optional ChatGPT integration compliant and testable. Ship a cohesive, delightful prototype, measure it with users, and let actual friction determine the next architectural abstraction.
