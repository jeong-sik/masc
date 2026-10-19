# Code question progress follows its request

Issue #43957 was observed in the actual macOS candidate
`2d2efb91ebaef48e9235f228ec4c2886d5f39d6f`, built by native run39206239764.
Its actual Pyright references picker returned four locations. After receiving
them, closing with Esc, or cancelling a subsequent question with new input, the
header still said it was asking. Selection, B return and input priority worked,
but the informational progress note outlived the request.

The shell had stored that progress sentence in `code_lsp_note`. A nonempty
location answer staged its offer without replacing the note; cancellation
retired the query without clearing the sentence. These are actual manual
observations, not screen-assertion tests.

The correction removes the shell's progress-note write. An accepted question
clears the previous settled note. The renderer derives pending progress from
the fetched request's `in_flight` state and its original source owner. Answer
admission and pending presentation share the workspace authority, read epoch,
Code view, scope, directory and source-file ticket check. A retained settled
query is not pending. A Ready refresh or Failed retry can still be in flight.
The existing history File note reads only settled notes.

Three semantic cases cover accepted request lifetime and location offers,
completion/failure/cancellation/Esc, Ready refresh and failed retry, suppression
or refusal without erasing another observation, replacement questions and
withdrawn source ownership. They inspect state and request identity, not text,
layout, row order or PTY frames. Their execution and matching new-source UI
proof are separate from parsing and source review.

This correction does not change source-query dispatch, result choice, B
history, the location return progress note, protocol positions or input order.
It does not turn the predecessor's 74 native tests into proof for this source.
Native compilation, scenario execution, guarded approval, integration and
operator installation remain separate evidence stages. The full music and
nonmusic rich TUI objective remains active.
