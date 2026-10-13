# Library redesign

Mode: Operate, with Read detail. Scope: ContentView, library pagination/filter metadata, and the Library/#general handoff. User-approved native sidebar/list/detail structure; Apple design language and ChatGPT restraint are binding. No graph navigation or second composer. Preserve graph code/data, canonical persistence, capture recovery, editing and confirmed deletion.

## Direction contract

THESIS: Library makes saved evidence inspectable and ready for conversation, not a visualization dashboard.

OWN-WORLD: System typography, semantic macOS colors, SF Symbols, native selection and list controls, quiet separators. System light/dark appearance. No decorative cards or branded status bars.

STORY: Browse by type or filing home, search locally, read rendered content and its provenance, select up to four documents, and carry them into #general without sending a request automatically.

FIRST VIEWPORT: A compact library toolbar above three resizable regions: a 180–210pt filing sidebar, a 300–360pt searchable list, and a generous reading pane. Import/new note are secondary toolbar actions. Chat handoff sits beside document actions.

FORM: The user's pinned sidebar → list → detail composition supersedes concept exploration. Code-led native build, no raster assets. Multi-selection and linked source/artifact navigation are the signature behavior.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
