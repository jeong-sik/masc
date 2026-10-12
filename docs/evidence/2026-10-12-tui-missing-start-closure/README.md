# Content closure when a start is missing

Base: `a7299c6ccf28b1071c8e8aa51c56628412cc6d0ac9` (rebuilt L16 tip; original base `b5a1ead3016c697a89d25d4757516f873756ada8` (#42505)).

Source finding: TUI discarded an end for an unknown index even inside the exact current response. A subsequent observed header or indexed Thinking delta could reopen that occurrence. The dashboard already retains same-response unknown-index closures.

Retain a closed occurrence for the exact current response even if the start is absent (tombstone in `active_model_content`). End cannot admit an unknown/future response (non-current scopes stay ignored). Appending the closed occurrence leaves existing open piece priority intact. A new response may reuse the index. Indexed Thinking for a closed thinking occurrence retains its bytes without moving the model signal. Admission is keyed on the content scope only; response-identity admission stays separate work. No text matching or fabricated reasoning.

Verification: syntax-only parsing passed for the two changed OCaml files, as did `git diff --check`. Added a registered transcript-state fixture including late exposed Thinking byte retention, but it is unexecuted. No full typecheck/build/CI, installed binary, runtime/socket, visible TUI or screenshots. The full chat goal remains incomplete.
