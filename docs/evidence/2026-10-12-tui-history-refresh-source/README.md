# History refresh source ownership

Base: `ac44afc75bbf812f4327b18a2fe7595675c27707` (#42523).

The executable pruned session rows before typed timeline reconciliation. Its input/failure replacement sets used raw IDs, so a foreign/unknown history input could delete local input before the corrected assembler saw it. Incoming user rows also inherited local send time through raw turn IDs, and ordinal counters merged distinct source kinds.

Refresh replacement sets now use reported Operation sources; failure replacement additionally requires its origin ID to agree with that Operation. Session input/error removal requires exact reported source. Local send-time lookup checks Operation ownership, and only incoming Operation input rows can inherit it. Ordinals use existing chat_turn_key, separating observed execution kinds from unobserved identity. No body, prefix or heuristic match.

Executed unchanged extracted production refresh-pruning/local-time functions, incoming timestamp decision and ordinal function in a minimal typed interpreter harness. Output replacement and final row construction are explicit external stubs. Parent exit1 (foreign refresh deleted input); revised exit0 for foreign/unknown input preservation and clock refusal, genuine Operation input replacement/time, foreign failure preservation and per-source ordinal separation. Artifacts: `/tmp/masc-tui-history-refresh-source-20261012/`. This proves those isolated decisions, not full HTTP ingestion, output replacement, row construction or visible chronology.

Syntax-only parsing of changed masc_tui.ml passed, as did diff whitespace. No new layout/row-order tests. Full typecheck/build/CI/runtime/screenshots/formal approval/merge unverified. Existing output-replacement/primary-identity and remaining ingress boundaries still need audit; whole goal remains active.
