# Antigravity native terminal lifecycle

Base: `6552c2949392335bffb0993296391a8037e92be9`.

Native blocks now retain a closed state for their exact provider identity for
this projection lifetime. Finished-before-start and Active-after-finished cannot
open a block. An active block retires before calling the completion observer;
the actual completion is delivered before ContentBlockStop so the chat bridge
can retain its outcome. Duplicate finishes cannot invoke that observer twice.

At Turn_finished, still-open native identities retire before stop publication.
Their blocks close without synthesizing a successful native completion.

The existing CLI fixture includes repeated Active, Done followed by late Active,
and an unfinished second step. It checks two native starts and exactly one stop
per started native block, and preserves all eight raw starts across both turns.
These assertions concern stream block lifecycle, not TUI row order or text.

Validation: both changed OCaml files passed syntax-only parsing and diff
whitespace checks. The fixture was not executed. No Dune build, CI, installed
runtime, or screenshot proof is claimed. Independent source review requested.

Remaining: callback failure/cancellation, text and MCP terminal cleanup,
post-terminal unnamed identities, and provider-wide equivalent lifecycle
boundaries remain to be verified.
