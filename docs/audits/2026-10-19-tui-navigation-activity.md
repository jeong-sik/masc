# Code navigation activity belongs to its request

Issue #43986. This change keeps the source reading and its settled observations
separate from a pending return or different-file language-server location.

## Reproduced behavior

Native source `7af92dc1a6629f4636410649f5d5217c8954e949`, built by run
39210114295 with workflow `b2bfd720065d87538d5aed6918297b9eb6f3ac95`, ran
against its matching isolated server. Code opened `src/score.py`, then
`notes.txt` through the finder. While the owned server was paused, `B` began
a return and `j` cancelled it. After the server resumed and the late read
returned, the current file correctly remained `notes.txt`, but its header
still said `Returning to src/score.py`.

This was a manual observation with controlled server delay. It does not prove
an independently timed network race or serialize internal focus/cursor state.
The old artifact's 77 passing focused cases do not execute this correction.

## State change

Before, `start_return` wrote progress into `code_lsp_note`. Input retired
`code_navigation` without erasing that stored progress. After, the renderer
derives return/location activity from the original navigation owner and its
requested destination. It uses the same predicate as response admission and
destination commit. No timer, progress cache or additional request is added.

| Observation | Source and history | Navigation activity |
| --- | --- | --- |
| Read pending | Original reading and history retained | Current owner and destination |
| Received, input queued | Still original reading | Remains until admission or cancellation |
| Cancelled or owner changed | No late destination admission | No activity from the old request |
| Read failed | Source and return entry retained; failure observed | Ended |
| Explicit retry | Source, history and observed failure retained | New owner |
| Idle successful admission | Destination commits; return consumes its entry | Ended |

Workspace/read authority, Code view, source scope/directory/file ticket and
the original history object must still match. Merely receiving a destination
does not authorize navigation. An old success/failure cannot finish a retry.

## Verification scope

`bin/masc_tui_types.ml` supplies the shared owner predicate and pending
projection. `bin/masc_tui_code_results.ml` uses that predicate for start,
response admission and idle commit; `bin/masc_tui_render_code.ml` consumes the
same pending projection without a new results-module dependency.

Two semantic cases in `test/test_tui_workspace_entries.ml` exercise retained
observations through cancellation, obsolete response, failure, retry and
successful admission, and both actions through input/view/scope/directory/
same-file-ticket/history/read-authority changes. They inspect state, original
requests and admission decisions, not screen text, layout, row order or PTYs.

Changed OCaml parsing and whitespace checks passed. Independent review of the
source correction found no P0/P1/P2. New type checking, execution of the cases
and visible behavior must be established by a matching native candidate;
the old artifact and a source review are not that evidence. Keep execution
receipts specific to their source and workflow identities. Overall music and
nonmusic integration, operator installation and Keeper tool execution remain
separate requirements.
