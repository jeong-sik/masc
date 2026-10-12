# Codex observed content terminal closure

Base: `62ab7efa93f2a3006f622465725b3032bab4001d`.

Codex runtime accepts a normal turn/completed after exposed reasoning deltas,
without requiring a separate reasoning item/completed. The Keeper projection
previously only closed reasoning on Thinking_completed. Turn_finished emitted
MessageStop without sweeping content indexes, leaving that observed block open.
Text indexes could have the same gap when their content boundary was omitted.

Turn_finished now sweeps recorded text and thinking indexes through the existing
idempotent stop_content. Explicitly ended blocks do not close twice. The sweep
closes transport content only and generates no thinking text or tool outcome.
Native and dynamic tool lifecycles are unchanged by this unit.

The existing process fixture has an opt-in unfinished_reasoning case. It sends
one exposed summary delta without reasoning item completion, then an ordinary
completed final answer and turn terminal. A new registered assertion requires
forwarded reasoning and exactly one block stop per observed reasoning index.
This is an SSE lifecycle check, not a TUI layout/text/order test.

Validation: syntax-only parsing passed for adapter and fixture and whitespace
checks passed. The process fixture has not been executed. No Dune build, CI,
formal approval, installed runtime or screenshot proof is claimed. Independent
source review requested. Claude/native/dynamic terminal boundaries and overall
multi-runtime chat correctness remain incomplete.
