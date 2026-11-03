# Gleanary: Agent-Native Personal Knowledge System

**Status:** Product and behavior specification for the shipped app.
UI and visual design live in `DESIGN.md`.

**Last updated:** 2026-10-31

---

## 0. Working Rules

1. **Preserve working code and user data.** Extend the current
   persistence model. Never drop tables or rewrite the database without a
   tested, reversible migration and a recovery path.
2. **Reuse before adding.** Check for an existing model, table, search
   index or service before creating another.
3. **Avoid speculative infrastructure.** No server backend, graph
   database, extra runtime, agent marketplace or elaborate ontology
   because it might be useful later.
4. **Keep security and privacy real.** SQLite is the local source of
   truth. Treat ingested text and model output as untrusted. Keep
   credentials in Keychain. Require review for consequential knowledge
   changes.
5. **Don't claim what isn't tested.** No fake functionality, mock
   retrieval hits or invented citations in the production UI.
6. **Prefer a polished, narrow experience** over a broad but hollow one.

---

## 1. Product Thesis

**Gleanary is a local-first personal information factory.** It helps a person acquire, organize, find, evaluate, connect, and synthesize information through a **single persistent, shared conversation** with a small team of specialized agents.

The user should not need to know whether their request is technically ingestion, retrieval, metadata normalization, research, synthesis, or curation. They express an intent, optionally `@mention` a specialist, and Gleanary handles the underlying work.

### North-star experience

1. Open Gleanary and see one conversation, `#general`.
2. Paste an article or arXiv URL and ask Gleanary to save and summarize it.
3. The librarian records the canonical source and files it in the current Johnny Decimal scheme.
4. The researcher produces a useful, grounded summary, not just a generic restatement.
5. The curator notices relevant existing material and offers a meaningful connection or consolidation.
6. The agents communicate naturally, with visible contributions only when useful.
7. The user can interrupt, address any agent, inspect the source and generated artifacts, approve proposed changes, and retrieve the information later through ordinary language.
8. Restarting the app does not lose the conversation, source, artifacts, or associations.

### Product principles

- **Local-first:** knowledge and conversation are owned by the application, not a model provider.
- **One room:** a natural chat-first workspace, not a set of independent chatbots or a dashboard maze.
- **Agent teamwork without theater:** meaningful conversation, spontaneous relevant participation, visible handoffs, minimal robotic status chatter.
- **Bring existing knowledge:** preserve existing notes and SQLite content; support import/adaptation rather than forcing a new system.
- **Source-grounded output:** keep traceable links from generated material to the original source(s).
- **Simple structure now, extensible later:** sources, artifacts, categories and associations; do not invent an elaborate knowledge ontology.
- **Native and responsive:** SwiftUI UX, streaming feedback, accessible controls, keyboard friendliness, actionable states, cancellation.
- **Useful offline:** users can always browse/search saved content; on-device inference works where Apple's supported models are available.

### Non-goals

- A full research graph or claim-level epistemic ontology.
- Fully autonomous unattended research loops or continuous web crawling. Scheduled maintenance of the user's own library (§7.4) is in scope: bounded batches over saved items, with the same permission policy as chat.
- Perfect support for every PKM convention; **Johnny Decimal first**.
- A hosted multi-user SaaS, sync server, organizations, collaboration accounts, or multiple channels.
- Building a separate CLI, web app, or Pi-based runtime as the primary user interface.
- A universal plugin architecture, tool marketplace, generic workflow DSL, or agent voting system. Automation recipes (§7.4) are a fixed, typed structure, not a scripting language.
- A mandatory ChatGPT account or assumption that a ChatGPT subscription provides unrestricted API access.

---

## 2. Known Limits

- Chat search (`search_library`) matches words and meaning only. It has
  no date or time filters, so phrases like "last week" are ignored.
- ChatGPT sign-in and inference need a real eligible account. Automated
  tests cover OAuth, tokens and consent with fixtures, not a live account.
- A YouTube link without an authorized transcript is saved as metadata
  only, and research on it is declined rather than guessed.
- Source-grounding checks reduce model errors but don't prove their
  absence.

---

## 3. MVP Experience: One Channel, Five Agents

### 3.1 Unified conversation

The principal interface is `#general`, a persistent chronological feed of messages from the **user** and these **five agents**:

| Agent | Handle | Responsibility | Domain authority |
|---|---|---|---|
| Assistant | `@assistant` | Interpret intent, facilitate, route, coordinate and ask for needed approvals | Task goals and user-facing clarity |
| Researcher | `@researcher` | Read, compare, analyze, summarize, synthesize information | Findings and evidence |
| Curator | `@curator` | Retrieve, connect, identify gaps/duplicates/conflicts and improve knowledge quality | Relevance and curation recommendations |
| Librarian | `@librarian` | Ingest, identify, normalize metadata, categorize, file, ensure structural integrity | Persistence and organization |
| Writer | `@writer` | Turn gathered evidence into finished documents in the user's chosen writing style (§7.6) | Structure, voice and readability of composed documents |

These are **task-scoped roles with real tools**, not permanently running LLM personas. Their differences must arise from their instructions, tools, responsibilities, and mutation authority.

Presentation groups consecutive specialist messages and their coordinating
reply by task. Gleanary is the main visible conversation voice; specialist
updates are expandable activity, not competing top-level speakers. Saved
results and review actions remain accessible while activity is collapsed.
User messages and task boundaries keep their original order. Direct or
legacy specialist-only exchanges retain their final answer visibly.
This grouping does not alter the persisted transcript or model context.

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
- Empty state teaches the product through examples, not an agent-by-agent tutorial wall.
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
          ├── Librarian
          └── Writer
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

#### Model-led conversation

Normal conversation with ChatGPT or Apple Intelligence uses the bounded
model/tool loop. The model chooses reads, follow-up calls, clarification,
and its final answer. Do not route questions by keywords, intent-pattern
tables, or canned question-specific replies. Explicit UI actions such as
capture retry and resuming an approved scope remain application-owned.

- Return category, search, item, and pending-review reads as tool data.
  The model answers after seeing those results; the app does not post a
  taxonomy dump or search template instead.
- Bound each conversation to 30 turns and 120 calls. Reject missing or
  repeated call IDs, validate tool arguments, and propagate cancellation.
  Exhaustion and blank replies are failures, not inferred success.
- Expose existing capture, personal-note saving, source/web research,
  Writer compose/refresh, and linked-note-series workflows through one
  publishing tool. Permit one document-publishing workflow plus one
  source-capture batch per message. Document workflows accept four
  distinct item handles; a capture batch accepts up to 20 source-link
  handles read from live saved-item revisions. Supply the user request to
  the workflow, not instructions from retrieved content.
- Direct-URL capture requires a URL from the current user request.
  Follow-up capture can select links retrieved from saved artifacts when
  the user requests retaining those resources. Validate source-link
  handles and origin revisions before queueing; never infer permission
  from source content. Reading links does not enqueue captures. Models
  cannot approve, reject, or undo protected changes. Those stay in the
  UI; existing evidence checks and atomic publication remain mandatory.
- Preserve saved-item references in recent conversation context. A New
  Topic marker ends that context: history and recent references start
  after the latest marker, and nothing is deleted. Offer
  bounded, read-only conversation retrieval for older messages and full
  external-link enumeration for saved artifacts. Truncated chat excerpts
  are not grounds to ask the user to re-paste recoverable resources.
  Capture reuses the durable queue and existing Source identities,
  reports each job's actual state, and never equates a research citation
  with a retained original. Filing remains separately reviewable.
- Apple Intelligence uses guided generation for tool turns with an
  explicit smaller context boundary. Context or availability failures do
  not fall back to a fixed planner. Its existing four-item Writer scope
  and local drafting pipeline remain unchanged.
- Progress must not reopen an awaiting or completed workflow. A final
  model reply may describe an awaiting scope or committed series without
  approving the scope, changing published notes, or reopening its task.

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

## 6. Apple Intelligence + Optional Hosted Inference

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

**API-key providers:** OpenAI (API key), Anthropic, Google Gemini and
OpenRouter run through `HostedInference`, which builds every feature
from one provider call (`HostedModelAPI.generate`) plus optional web
search. The tool loop keeps its history in Responses item shapes; each
client translates them (Claude content blocks, Gemini parts with thought
signatures, Chat Completions tool messages). Structured output uses each
provider's documented mechanism: strict JSON schema, a forced Claude
tool, or Gemini's response schema limited to its supported keywords.

- Keys live in one Keychain item, are checked by listing models before
  they're saved, and are never logged or shown again beyond the last
  four characters. Replacing or removing a key cancels work started
  with it.
- Choosing a provider asks to share once, naming the company; removing
  its key withdraws that permission.
- Failures name the company and never silently switch providers.

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

### 7.4 Automations: scheduled library maintenance

Automations run repetitive library upkeep on a schedule, using the same agents, tools, permission policy (§4.4) and change proposals (§7.3) as chat. They work only on items already in the library; they never research or crawl on their own.

**Recipe.** An automation is a typed record, not a script:

| Field | Meaning | Example |
|---|---|---|
| Trigger | Interval, daily/weekly at a time, or an event (capture finished; a category's item count exceeds N) | Every 10 minutes |
| Selection | A deterministic, parameterized query over the library, chosen from built-in selectors. The model never chooses the items. | Sources with full text and no summary, newest first |
| Batch limit | Maximum items per run | 10 |
| Agent | The role that makes judgment calls | Researcher |
| Action | One built-in action: summarize, fetch, check access, propose links, propose filing, retitle, digest | Summarize |
| Output policy | `apply` (reversible, with Undo), `propose` (a changeset for review), or `report` (findings only) | Apply |
| Budget | Local-only or cloud allowed; maximum model calls per day; quiet hours; pause on battery | Cloud allowed, 200 calls/day |

**Output policy follows §4.4, enforced in code, not prompts:**

- Summaries, drafts, fetching unfetched bookmarks and retrying failed captures may `apply`.
- Linking, retitling, refiling or editing existing content defaults to `propose`. The user may promote an individual automation to `apply` for title and filing changes only, and every applied change keeps its Undo.
- Archive proposals default to `propose` (§7.5). The one exception: the link checker may be set to archive dead links itself, with Undo (see the link checker rules). Automations never trash or delete.
- Cloud inference requires the existing ChatGPT enablement and consent; an automation set to local-only never sends content off the Mac.

**Progress markers.** Selections that walk the library ("oldest first") must not revisit the same items every run. Store per-item, per-check timestamps (for example `accessCheckedAt` and `linksCheckedAt`), and select items that were never checked or were checked longer ago than the automation's recheck interval.

**Large libraries.** A library of thousands of items must be covered without manual tuning:

- Never-checked items come first, newest first, so anything just saved is in the next run; then whatever was checked longest ago.
- Checks that repeat (link checks and cross-linking) have a **Recheck items** setting: every week, month (the default), 3 months or 6 months. A run takes at least enough to get through what's due within that interval at its schedule, never fewer than the user's batch and never more than 1,000. Failing links are still retried the next day, and the archive rule (three failures over a week) is fixed. Summaries keep to the user's batch; the daily model budget limits them.
- Link checks run several sites at once, each site's links one at a time with a pause between, so no site sees a burst.
- Each automation shows what's due now and about how many runs that is, counted in SQLite rather than by loading the items.

**Runs.** Each run is persisted with its automation, start/end, items examined, items changed, items skipped with reasons, model calls used, and status (`succeeded`, `partial`, `failed`, `cancelled`). Proposed changes from one run form one changeset in the existing review sheet, and Undo applies per run. Runs are cancellable. Retrying a run never duplicates artifacts (§8).

**Scheduling.**

- Runs happen in-process while the app is open, scheduled with `NSBackgroundActivityScheduler` so macOS can defer them under load or on battery.
- A run missed while the app was closed runs once on next launch, not once per missed interval.
- Automations that work on new items (summaries, cross-linking) also run shortly after a save, once per burst of saves, rather than waiting for their schedule.
- Automations run one at a time and share a single lock with user-started ingestion and summaries.
- User-started work always comes first, and an automation run yields between items.
- Running with the app closed (a login-item helper via `SMAppService`) is a later, opt-in step, not part of the first version.

**Built-in automations.** Ship as templates with these defaults:

| Automation | Agent | Selection → action | Policy |
|---|---|---|---|
| Summary backfill | Researcher | Items with full text and no summary, filed or not → summarize | Apply |
| Bookmark fetcher | Librarian | Imported bookmarks never fetched, a few per run → fetch page | Apply |
| Link checker | Librarian | Sources by oldest `accessCheckedAt` → check the original URL | Report; propose URL updates and archives (or archive dead links, if set) |
| Cross-linker | Curator | Items with no links, by oldest `linksCheckedAt` → propose links with a one-line rationale | Propose |
| Unfiled filer | Librarian | Unfiled items → propose a primary category | Propose |
| Failed-capture retry | Librarian | Failed captures with a retryable error → retry with backoff (1 hour, 1 day, 1 week), then leave in Needs Attention | Apply |
| Weekly digest | Assistant | Items saved in the last 7 days → a digest note grouped by category | Apply (new note) |

Default settings, chosen so the two automations that only finish work you started are on, and anything that proposes or writes something new waits until you turn it on:

| Automation | On by default | Schedule | Items per run | Model calls per day |
|---|---|---|---|---|
| Summary backfill | No | Every 10 minutes | 10 | 200 |
| Bookmark fetcher | Yes | Every 30 minutes | 5 | 200 (summaries of fetched pages) |
| Link checker | No | Daily | 50, more to keep within Recheck items | None |
| Cross-linker | No | Daily | 20, more to keep within Recheck items | 200 |
| Unfiled filer | No | Daily | 40, more to keep within Recheck items | 200 |
| Failed-capture retry | Yes | Every hour | 10 | None |
| Weekly digest | No | Weekly | Lists up to 200 | None |

**Bookmark fetcher rules.**

- Selects imported bookmarks still unedited, with no page fetch queued, running or failed, that the fetcher hasn't tried; newest first.
- Fetches through the same capture path as opening a bookmark, so it upgrades the note in place and follows the Capture settings for summaries and page previews. If the automation is on-device only and ChatGPT writes summaries, pages are fetched without one. Each summary counts toward its model calls per day.
- One page at a time; a site already fetched in the run waits a moment first. The capture path applies the URL policy (no cookies or credentials, private and local addresses blocked).
- A fetch that fails is reported once and never fetched again unasked: the item keeps Try Again, and if the failure may pass, the failed-capture retry takes it from there. A fetch stopped in Captures isn't restarted. Undo puts the bookmark text back where the item hasn't changed since.
- Runs it starts don't raise the window's capture notice; the run's history reports them.

**Failed-capture retry rules.**

- A capture failure records whether it may pass on its own: a download that failed, an extraction that timed out, HTTP 408, 429 or 5xx, or YouTube refusing for now. Failures that need you (the capture browser, audio options) or never pass (HTTP 404, a locked or oversized file, a page with no text) are never retried.
- Tries come an hour, a day and a week after each failure, three in all; then the capture stays in Captures for you. Try Again by hand restarts the wait but not the count.
- A capture for an item since deleted or archived isn't retried. Retries apply directly; there's nothing to undo.

**Unfiled filer rules.**

- Selects live items filed nowhere, with no filing waiting in its own review or in Categorize Unfiled; never-checked items first, newest first, then those looked at longest ago, per Recheck items.
- Asks the same model, in the same batches and with the same saved answers as Categorize Unfiled, and proposes only existing categories. When nothing fits but a new category might, the run says so and leaves creating it to Categorize Unfiled.
- A filing under the same category that was proposed, applied, undone or turned down before is never proposed again. Nothing is filed until the proposal is applied in review.

**Weekly digest rules.**

- Lists items saved since the last digest still standing, at most 7 days back, grouped under their primary category in code order with unfiled items last, each linking back to the item. When more were saved than the digest lists, it lists the newest and says how many there were.
- Writes one new note, unfiled, and never edits another. Undo deletes it unless it was edited since; an undone digest's week is covered again by the next.
- A week with nothing saved writes nothing. No model is used. Digests are left out of later digests, the cross-linker and the unfiled filer.

**Link checker rules.** Most checks need no model; classify the response:

| Result | Handling |
|---|---|
| 2xx, page still matches the capture | Record `accessCheckedAt` |
| Permanent redirect (301/308) | Propose updating the source URL |
| 404, 410, or a domain that no longer resolves | Mark the source unreachable |
| 401/403, login wall or paywall | Mark restricted; never propose archiving for this alone |
| Refused by the URL policy (a local or private address) | Not a failure; never archived or proposed for archiving |
| Timeout or 5xx | Transient; check again later |

- Propose archiving only after the source has been unreachable on at least three checks spanning at least seven days.
- A **Dead links** option chooses between **Ask first** (the default, which proposes) and **Archive automatically**. Archiving automatically uses the same rule, records each archive as an applied change so the run's Undo unarchives it, and never archives an item whose archiving was proposed or done before: a proposal waiting for review stays there, and an Undo, rejection or later unarchive is respected.
- When proposing, look up the Internet Archive's Wayback Machine availability API and attach the nearest snapshot's link if one exists.
- The UI must state that the original link is gone but the locally captured copy is intact; "unreachable" does not mean the item's content is lost.
- Checks go through the existing URL policy and fetcher (no cookies or credentials, private and local addresses blocked) and are rate-limited per host.

**Pipelines (later).** A pipeline chains automations, each stage selecting only items the previous stage completed (for example: fetch → summarize → propose links → propose filing). Each stage keeps its own output policy, so links stay proposals even inside a pipeline.

**Creating from chat (later).** "Every morning, summarize anything new in Reading queue" makes the Assistant draft a recipe and show it as a card (trigger, selection, agent, action, policy, budget) with **Create Automation**. Nothing is scheduled without that confirmation, and the draft can only use the built-in selectors and actions.

**UI.**

- An **Automations** list, in the sidebar or Settings. Each row has an on/off toggle, schedule, last run (succeeded / needs attention), next run and **Run Now**.
- New automations start from the templates above.
- An automation's detail view shows its recipe and its run history; each run expands to its report and changeset.
- Pending proposals from all automations appear in one review queue with a badge, like Captures.
- Status text and counts follow the shared text motion in DESIGN.md.

### 7.5 Archive and trash

Two states, because they mean different things:

- **Archive** means keep the item but put it out of the way.
  - Archived items stay complete and are hidden by default from the library, Atlas, search and chat retrieval.
  - They're listed under **Archive** in the sidebar with their reason (for example "Original link unreachable since 2 Oct 2026") and the date archived.
  - **Unarchive** restores the item exactly.
  - Search offers "Include archived".
  - Automations may propose archiving; only the user applies it, except dead links when the user sets the link checker to archive them automatically (§7.4), each with Undo.
- **Trash** means the user is deleting the item.
  - Trashed items are hidden everywhere, listed under **Trash**, restorable for 30 days, then purged through the existing permanent-removal path, which already cleans up artifacts.
  - Only the user can trash an item, never an automation or agent.

**Implementation notes.**

- Add `archivedAt` and `archiveReason` to `notes` in a versioned migration.
- Filter archived items in the library, Atlas, search and retrieval queries, and keep their passages so unarchiving needs no reindex.
- `notes.deletedAt` already exists. Today deleting records a revision, sets `deletedAt`, and drops the item's passages and index jobs. Trash should build on that path rather than add a parallel flag.
- Restoring from trash must re-queue indexing.

### 7.6 Writer and writing styles

The Writer turns evidence the other agents gather into a finished document: a guide, comparison, overview or digest. It doesn't research, ingest or file. The Researcher stays close to sources (quotes, hedging, citations), while the Writer is responsible for structure, voice and readability. Keeping the two roles apart keeps each one good at its job.

**Writing styles.** A style is a named, structured profile chosen per request ("in Plain style") or set as the default:

| Field | Examples |
|---|---|
| Tone | Neutral, conversational, opinionated, technical |
| Reading level | Plain language (ISO 24495-1), general, expert |
| Structure | Summary first, tables first, short sections, bullets or prose |
| Conventions | US or UK spelling, units, currency, date format |
| Avoid | Banned words and phrases, marketing tone, emoji |
| Citations | Inline links, footnotes, or a sources section |
| Instructions | Free text, for example "explain jargon on first use" or "say when sources disagree" |

- Ship a few presets (for example Plain, Reference guide, Blog) so a new style never starts blank.
- Styles are user settings stored locally.
- A style's instructions shape wording only; they cannot widen the Writer's tools or permissions, and source content cannot change the active style (§8).

**Compose workflow.** Composing a document from many sources runs in stages, so no stage needs the whole library in one context:

1. **Gather (Curator).** Select candidates by category, search and semantic similarity, then show the list with suspected off-topic items marked. The user confirms or edits the scope before anything else runs.
2. **Extract (Researcher).** For each item, extract the facts the request asks for as structured records with a supporting quote and source reference. A fact the source doesn't state is recorded as "not covered", never inferred.
3. **Write (Writer).**
   - Compose the document from the extracted records in the chosen style.
   - Any grade or rating uses a stated scale, and the document defines it.
   - Every claim is traceable to its record's source, and conflicting sources are called out rather than averaged.
4. **Save.** Save the result as a new note linked to every source it used. It's editable like any note.

For example, "read my audio sources and write a hi-fi page organized by budget, split into IEMs, headphones and speakers, graded by bass response":
- gathers the audio sources and confirms the list;
- extracts product, type, price and what each source says about bass;
- writes sections by type, with budget tiers and a bass-response scale, and marks products whose sources don't discuss bass.

**Grounding.** Composed documents draw only on the user's saved sources by default. The model's general knowledge can be allowed per request, and anything drawn from it is marked as such in the document.

**Refresh.** A composed document records its request, style and source selection.
- **Refresh** re-runs the request: it gathers again, re-extracts only new or changed sources, rewrites the document, and shows what changed before saving a new revision.
- Refresh can also be scheduled as an automation (§7.4), with output policy `propose`.

**Providers.** Extraction can run on-device, one item at a time. Composing documents across many sources realistically needs ChatGPT's larger context; without it, the Writer should say so and offer to compose from a smaller selection.

**Progress and control.** Composing runs as a normal task with stage progress ("Extracting 12 of 37"), cancellation at any stage, and no partial document saved on cancel.

**As built (Phase 8).**
- **Gather.** One structured call reads only the request and returns search keywords, matching category codes, the facts to extract and whether general knowledge is allowed. Candidates come from the search index and the requested categories (and any items the person selected), capped at 60 with ChatGPT and 4 on this Mac. Writer documents are never gathered as sources. An item found only through a matching category, or only by a weak meaning match, is marked possibly off-topic and starts unchecked. The task waits in `awaiting_user` with a scope card; confirming resumes the same task, and Cancel ends it with nothing read.
- **Extract.** One call per section of one item (24,000 characters with ChatGPT, 3,000 on this Mac, at most 4 sections). The app keeps a fact only if its quote appears in that section and its field was requested; every requested field with no kept fact becomes a "not covered" record. Records are cached per source, content hash and field list.
- **Write.** With ChatGPT, the Writer runs on the shared tool loop with exactly two tools, `read_records` and `write_document`; a style can't change that list. The draft is structured (sections, paragraphs, bullets or table rows, a scale and conflicts), and every block names the records it rests on. The app rejects uncited blocks, unknown records, grades not on the stated scale and unmarked general knowledge, then renders the Markdown itself: citation markers, a "Not covered by your sources" section built from the records, and a Sources list. On this Mac, a single structured call writes the same draft for up to 4 sources.
- **Styles.** Plain, Reference guide and Blog presets plus one editable custom style, stored in UserDefaults; a default in Settings › Writing, or "in Blog style" in the request. Citations are numbered markers or linked source titles; the Sources list is always included. The style is recorded with the document.
- **Save.** The note, its provenance, a link to every cited source and the request are written in one transaction, and only while the task is still running, so Stop at any stage saves nothing.
- **Refresh.** "Refresh Document" in an item's More menu, or "@writer refresh" with the document selected. It keeps the person's earlier checks, adds new on-topic matches, and doesn't ask to confirm the scope again; the review is the gate. If no source is new, changed or gone, it says so without rewriting. Otherwise the new text is a pending document revision, plus links to newly cited sources, reviewed as a line diff; applying saves a new revision and Undo puts the earlier text back.
- **Weekly digest.** The digest automation can be written up by the Writer (off by default). It reuses the extract and write stages on the week's newest items (60 with ChatGPT, or all of them on this Mac when there are 4 or fewer) with fixed facts to extract and the default style, written as the person's own notes (never "you" or "your saves", and no line saying how it was composed), counts its model calls against the automation's daily budget, lists any further items under Also saved, and is undone like the listed digest. When it can't run (no model, on-device only with ChatGPT as the provider, too many items on this Mac, too little budget, or the Writer failing), the run says why and writes the usual list.
- **Later.** Multiple custom styles, scheduled refresh as an automation, and adding items to a scope beyond those gathered or selected.

---

### 7.7 Typed notes, templates, and personal tasks

Implement two connected slices, without a second document store or
inference dependency:

- **Slice 1: reusable notes.** Optional Meeting, Project, Decision, and
  Person types add validated text/date/linked-note properties to ordinary
  Markdown notes. Stock Meeting, Project, Decision, Checklist, and Person
  templates create drafts. Personal templates support duplication,
  editing, deletion, and save-from-note. Template changes affect future
  notes only. Source/Note identity, provenance, and filing remain separate.
  Properties and tasks can annotate a source without altering its retained
  original; the explicit original-source reading mode stays read-only.
- **Slice 2: shared tasks.** Explicitly track a local checklist item, or
  create/link a task from the reading pane. One versioned task record owns
  title, status, plan, deadline, project, and origin. The note and Tasks
  edit that same record. Tracking atomically replaces the local checkbox
  with a stable reference; blank template checkboxes never create tasks.
- Tasks has Inbox, Today, Upcoming, All, and Completed views. Inbox means
  open with no plan or deadline. Today includes due-today, overdue, and
  planned-through-today open work. Upcoming excludes that current work.
  Planned dates carry forward without becoming overdue deadlines. Dates
  are local Gregorian calendar days; reminders are not implied.
- Project notes show their assigned tasks and explicitly placed tasks.
  Linked-note properties have searchable, bounded pickers, backlinks,
  and read-only canonical graph edges. Creating tasks does not create
  synthetic notes or alter graph identity.
- Preserve optimistic revision checks and atomic note/property writes.
  Task versions reject stale updates. Removing a placement does not delete
  its task; deleting an origin keeps tasks available with the origin
  cleared. Template bodies are inert and cannot run code, captures, or
  inference. Save-from-note requires review and replaces tracked task
  references with empty local checkboxes.
- Markdown export resolves task placements to current checkboxes and
  includes JSON-compatible frontmatter for properties and task IDs.
  Reading, selecting templates, and browsing tasks do not create records.
- Verify draft-only creation, migration/reopen, property validation,
  canonical link projection, checklist promotion and rollback, shared
  completion, stale edits, date semantics, pagination, export, deletion,
  native input, and narrow/light/dark layout using synthetic local data.

Custom type/property builders, saved type views, recurrence, reminders,
calendar integration, dependencies, assignments, automatic entity merging,
and reviewed AI task extraction remain later slices.

### 7.8 Source acquisition

One Capture setting, from lazy to eager, decides how links inside saved
sources are followed: Off, Lazy, Suggest, Balanced (the default), Eager,
and Explore.

- After a capture you made finishes, its links are recorded as
  candidates with the surrounding line, provenance, hop, score, state,
  and reason. Links back to the source itself are skipped. A link found
  again in the same source keeps its state, so dismissals stick.
- YouTube captures keep the description and a pinned comment the channel
  itself wrote as a "From the creator" section. Summaries and research
  read only the transcript. General comments are never fetched.
- Scoring uses provenance and wording. Creator recommendations ("I'd
  recommend reading…") score highest; social profiles, sign-ups, sponsor,
  storefront, affiliate, and muted-site links are filtered. Bare domains,
  same-site links, and shorteners score lower. Each hop multiplies the
  score by 0.6. Eager and Explore also weigh closeness to the library's
  indexed passages.
- Lazy records links. Suggest offers up to five per source with Save,
  Dismiss, and "Don't suggest links from this site" under the chat reply.
  Balanced also saves up to three creator recommendations per source and
  twenty per day, one hop out. Eager also saves creator and cited links
  close to the library, up to ten per source and sixty per day, two hops
  out. Explore adds the Source explorer automation, which re-judges the
  strongest open links against today's library and saves those that
  qualify, up to three hops and 150 per day.
- Categories can set their own level; subcategories follow their parent.
  A chat capture is re-judged after filing, before anything is saved.
  "Explore Links from Here" follows one item's links once with Eager
  rules, whatever the level.
- Automatic saves skip the AI summary and link back to their origin with
  the reason. A chat capture replies first, then saves and says what it
  saved. The weekly digest lists the week's automatic saves under "Found
  for you". Automatic saves left unopened, unfiled, and unlinked for 30
  days are archived, which is reversible; opening one ends its probation.
- When the AI provider is available, a model reads the wording around up
  to 20 of a source's strongest links as recommendation, reference,
  promotion, or other, and that reading replaces the cue phrases. The
  reading is stored, so re-judging costs no call; without a model, cue
  phrases decide.
- Automatic saves respect each site's robots.txt (RFC 9309): a missing
  file allows everything, and a file the site can't serve blocks until it
  can. Saves you choose act for you and skip it. Automatic fetches from
  one site are at least two seconds apart, longer when Crawl-delay asks,
  up to 30 seconds. One site may take at most 3, 5, or 10 automatic saves
  a day at Balanced, Eager, and Explore.
- Automatic saves appear in the library graph as "Found via" connections
  from where they were found.
- Fetched text is untrusted data that only feeds scoring. Muted sites
  are listed in Capture settings with Unmute.

### 7.9 Research audits

A research audit answers "what am I missing?" about a research
question, using only the person's saved items. It reports what the
audited evidence doesn't establish, never that research doesn't exist.
Design and stage plan: `RESEARCH_GAPS.md`.

- **Start.** Chat starts it through the `audit_research` workflow, with
  ChatGPT only. On-device models decline before reading anything.
- **Scope.** One structured call proposes search keywords, categories
  and up to 6 criteria (label, answer criteria, origin quote, other
  terms, an answer phrase). A criterion starts checked only when its
  origin quote is really in the request; the model's suggestions start
  unchecked and are labeled. Candidates come from the Writer's gather
  stage, limited to sources and the person's own notes, since
  summaries, research results and composed documents are model-written.
  The task waits for the scope card; nothing is read until Run Audit.
- **Read.** Each confirmed item is read with the Writer's extraction,
  so only verified quotes count, cached per item text and criteria.
- **Disprove.** For each criterion nothing answered, three library-wide
  searches (the label, its other terms and an answer phrase) find
  matching passages in up to 6 items, which are read for an answer.
  An answer outside the scope rejects the gap and says where it was.
- **Coverage.** Supported, Not found, Unknown or Not checked, as text.
  Unknown replaces Not found when an item was only partly saved or
  couldn't be read, or a search or read failed. Keyword-only search is
  noted but accepted.
- **Report.** A chat card shows up to 3 possible gaps (more behind Show
  More), each with bounded wording, why it matters, and how it was
  checked; then every other criterion with its quotes. Dismiss hides a
  finding without changing its coverage. A report whose items changed
  or were deleted is marked stale, and quotes from deleted items aren't
  shown. Reports live with the conversation; clearing it removes them.
- **Later.** Evidence imbalance, explicit questions from notes,
  dismissals that persist across audits, and proactive audits.

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

## 9. Test Plan

Prefer deterministic unit and integration tests with temporary databases
and model/network fixtures; add UI tests for critical interactions.

1. **Database and migrations:** existing sample DB upgrades without data loss; foreign keys and associations hold; app can reopen and retrieve records; rollback/backup recovery path is documented and tested where applicable.
2. **Source identity/dedup:** equivalent arXiv links resolve to same source; distinct version/content cases aren't silently collapsed; duplicate submissions don't create redundant artifacts unexpectedly.
3. **Classification:** source supports primary JD category and secondary memberships; artifact can differ from parent source; invalid category codes are rejected according to selected policy.
4. **Ingestion/extraction:** valid URL, malformed URL, network timeout, blocked URL, empty content, missing YouTube transcript, document parsing failure, and recoverable retries.
5. **Inference providers:** streaming delivery, cancellation, structured response validation, timeouts, error propagation, provider availability, fallback/selection and secret redaction.
6. **Agent routing:** direct `@mentions`, unmentioned default, irrelevant-agent suppression, handoff budget, no infinite delegation, failure of a child task, cancellation while another agent speaks.
7. **Persistence and UX state:** chat/references/task status across restart; stale proposal cannot clobber a changed artifact; reject and accepted changes are accurately reflected.
8. **Security:** prompt injection in an ingested article cannot execute prohibited tools, request private local files or turn a draft into a committed destructive operation.
9. **Automations:**
   - Schedules and missed-run catch-up are tested with an injected clock.
   - Selections respect batch limits and progress markers.
   - Output policy is enforced in code, e.g. a `propose` automation cannot apply.
   - Budgets and local-only mode hold.
   - Cancellation and retry leave no partial changes.
   - The link checker classifies synthetic responses correctly and proposes archiving only after its failure threshold.
   - Archive and unarchive round-trip, and trash restores within its window.
10. **Writer:** the gathered scope is confirmed before extraction runs; extraction marks uncovered facts instead of inferring them; composed claims carry source references; style instructions change wording but cannot add tools or permissions; source text cannot change the active style; cancelling saves no partial document; refresh re-extracts only new or changed sources.

---

## 10. Engineering Quality Bar

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

## 11. Official Reference Pointers (Verify Before Implementing)

The following references guide integration. They do not supersede current SDK documentation, app distribution policy, the actual repository, or the tests.

- [Apple Foundation Models: LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- [Apple Foundation Models: generating content and tasks](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Apple Foundation Models: tool calling](https://developer.apple.com/documentation/foundationmodels/tool)
- [OpenAI: Sign in with ChatGPT, open-source local tools](https://developers.openai.com/siwc/token-sharing-open-source)
- [OpenAI: registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [OpenAI: models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [OpenAI: current preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [OpenAI: account sessions and token refresh](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
