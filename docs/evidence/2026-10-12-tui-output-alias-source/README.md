# Output alias retains observed source and phase

Base: `76ecc229b330679e0ffcc6f898cfd8780feffc05` (#42525).

Session output replacement used raw request ID + role, and reply search aliases separately fabricated Operation/Autonomous_turn ownership from role/raw ID when observation was absent. Equal IDs could replace a local reply with foreign/unknown output; same-role progress could also grant the alias.

One `chat_output_alias_source` requires observed source and Keeper/autonomous Turn_output. Replacement aliases require matching source and role; search reply aliases share the helper and invent no missing owner. Exact structural identity replacement remains unchanged and keeper-bound. No body/prefix/heuristic matching added.

Executed unchanged extracted production helper/replacement functions in a minimal typed interpreter state: parent exit1 (foreign alias replaced local reply); revised exit0 for foreign/unknown refusal, progress refusal, keeper isolation, real Operation/autonomous aliases, exact identity and unknown-local alias refusal. Artifacts: `/tmp/masc-tui-output-alias-source-20261012/`. This is isolated alias decision execution, not whole history refresh, search index or screen proof.

Three changed OCaml files parse; diff whitespace passes. Registered state fixture remains unexecuted. No build/typecheck/CI/runtime/screenshots/formal approval/merge.

Important remaining authority gap: Turn_output describes a row phase, not terminal operation completion. The history decoder currently collapses checkpoint/native operation delivery distinctions to the same source. This unit does not prove terminal versus checkpoint speech replacement. Primary identity, durable speech slots and full runtime/provider/interleaving/async/visible acceptance remain follow-ups; full goal stays active.
