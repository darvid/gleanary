# Infactory

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

The shipping app is native macOS 26+, written in SwiftUI. No web or mobile surface is in scope.

## Users and purpose

A person building and using a local knowledge library through a persistent #general conversation. Save sources, find material, ask grounded questions, compare sources, and review connections without learning internal agent routing. SPEC.md is the product authority.

## Operating context

Conversation is the primary workspace. Library is its companion for browsing, searching, reading, filing, capture recovery, and selecting evidence to take back to chat. The user approved a sidebar → searchable list → detail pane and asked for Apple design language with ChatGPT-inspired restraint. Graph and Mind Map navigation are deferred; preserve their code and stored data.

## Capabilities and constraints

Existing SQLite notes, captured originals, many-to-many source/artifact associations, Johnny Decimal categories, and reviewable links remain canonical. On-device inference is preserved; optional ChatGPT requires explicit sharing consent. Keep destructive changes behind confirmation. Library search and reading must not require inference. Render Markdown in the detail pane. Respect system appearance, keyboard access, and accessibility.

## Product principles

- Local ownership and source provenance.
- One conversation, meaningful specialist contributions, no status theater.
- Retrieval and inspection before mutation.
- Native, quiet, task-oriented controls.

## Evidence

The existing app and isolated fixture tests establish implemented capabilities. Screenshots use synthetic data; they are not external GUI or VoiceOver certification. Genuine ChatGPT inference remains to be verified independently.
