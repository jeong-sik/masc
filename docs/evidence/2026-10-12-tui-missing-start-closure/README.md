# Content closure when a start is missing

Base: `b5a1ead3016c697a89d25d4757516f873756ada8` (#42505).

Source finding: TUI discarded an end for an unknown index even inside the exact admitted current response. A subsequent observed header or indexed Thinking delta could reopen that occurrence. The dashboard already retains same-response unknown-index closures.

Retain a closed occurrence for an exact current response even if the start is absent. End cannot admit an unknown/future response. Appending the closed occurrence leaves existing open piece priority intact. A new response may reuse the index. No text matching or fabricated reasoning.

Measurement: copied the actual unchanged `apply_model_content`, `response_is_closed`, and `response_precedes_current` source into a minimal typed OCaml interpreter harness. Parent exited 1: late observed piece reopened after missing start. Revised source exited 0 for missing-start closure, preservation of another open piece, rejection of a future response end, and new response index reuse. Private reproducible harness and logs: `/tmp/masc-tui-missing-start-closure-20261012/`. This is isolated execution of production functions with minimal surrounding types, not full transcript typechecking or an executed TUI fixture.

Syntax-only parsing passed for the two changed OCaml files, as did `git diff --check`. Added a registered transcript-state fixture including late exposed Thinking byte retention, but it is unexecuted. No full typecheck/build/CI, installed binary, runtime/socket, visible TUI or screenshots. The full chat goal remains incomplete.
