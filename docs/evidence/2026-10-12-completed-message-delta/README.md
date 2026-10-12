# Completed-message late delta closure

Base: 04b8b6041752525b201ffcc4e363f02a6af8e5f6.

The shared official-client text stream remembered identity-owned completions to
suppress duplicate completion events, but forward still appended deltas for
those identities. Muse's actual serve callback calls forward on Text_delta and
complete_message on Text_completed; a late/replayed delta could append completed
speech again, displace a newer current identity and contaminate final remainder.

forward now refuses only supplied identities already completed. No provider ID
is invented for unobserved deltas. complete_message computes its missing bytes
before recording closure, so completion itself still contributes an unseen
suffix or body. This pure synchronous step has no observer reentry.
.mli documents late delta closure. No content-phrase heuristic is added.

## Direct bounded measurement

Interpreted the complete actual production module with no substituted types,
helpers or effects. Artifacts:
/tmp/masc-completed-message-delta-20261012/{generate.py,parent.ml,current.ml,parent.log,current.log}.

Parent exit2: closed identity forwarded late delta.
Current exit0: missing completion suffix and completion-only body retained;
closed-ID delta before/after a newer message refused; duplicate completion
refused; live newer delta and final remainder preserved; empty completion still
closes identity; absent-ID delta remains unobserved and preserved.
Assertions concern emitted protocol bytes and closure decisions, not TUI layout,
wording or row-order snapshots. These synthetic cases do not establish actual
provider late-delta frequency or full callback/bridge/reducer integration.

Both production interface/implementation syntax-only parses and diff check pass.
No full typecheck/build/CI/registered fixtures/provider runtime/UI/installation,
formal GitHub approval or merge evidence. Full multi-provider/interleaving/async
objective remains active.
