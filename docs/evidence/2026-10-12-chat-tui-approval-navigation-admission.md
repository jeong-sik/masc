# TUI approval navigation retains admission identity

Base: `913d597ea8864cf8ad153ec17d17b11eb380324e`.

Home request identity and Agenda awaiting/destination identity now carry the opaque typed approval admission ID. Provider call IDs remain display metadata rather than navigation ownership. The actual Agenda open handler resolves the current matching admission, refuses a missing target, and opens that exact approval detail. It retains the selected request identity for existing refresh reconciliation.

The existing selection-state feature case now seeds two distinct admissions sharing one provider call ID. It checks distinct Home action identities and reachability, Agenda destinations and preservation of the selected admission across inventory reorder. No new text, layout, snapshot or PTY assertions were added.

Validation: OCaml 5.5.1 syntax-only parsing of all six changed ML/MLI files succeeded without diagnostics; source hashes and exits `/tmp/chat-tui-approval-navigation-syntax.json`. `git diff --check` passed. The modified tests were not executed; syntax parsing is not typechecking or functional evidence. Existing Agenda/Home Dune libraries already directly declare `masc`, which owns the opaque ID module.

The preceding corrected cumulative approval authority unit received independent SOURCE PASS at its own exact head. That does not prove this new navigation change or formal GitHub approval. Chat answer receipt owner/label, timeout-to-late-store publication, unseen terminals/frontier/resource retirement, all provider/runtime behavior and installed visible UI remain incomplete. No local Dune build, CI, formal approval, merge, deployment, runtime or screenshots were verified.
