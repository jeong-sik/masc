# Reading an MSX observation

The MSX observer package receives captures from the existing machine owner.
Each selected row identifies a machine, a machine incarnation, a frame, and a
wall-clock observation time. A load or restore starts a different incarnation.
Frame 20 in one incarnation and frame 20 in another are different coordinates.
The frame value does not identify an in-game turn, calendar date, score, or winner.

`fields.matches_binding` records whether that capture matches the requested
machine and optional incarnation. `clock.domain` includes the machine and its
incarnation, and `clock.value` records the frame. Keep both clock fields when
comparing observations. `actor = null` means the actual actor is unknown.

The host namespaces a row ID with its installed instance and observation
sequence. Repeated observations may describe the same frame. Counting those
records measures observations, not game actions. Preserve the row IDs instead
of merging records on their frame number.

Source coverage has its own source identity, incarnation, cursor, completeness,
and detail. A selected row does not prove that all events in a time interval
were observed. An unavailable source or a partial query remains incomplete;
it does not establish that the game stopped or that a Keeper failed.

`fields.input_ledger` links the input history captured with this frame. A supplied
descriptor names `msx-input-jsonl`, the exact entry count and an evidence reference
whose JSONL records preserve native `frame`, `who`, `key` and `edge`. Its count
matches `fields.input_cursor`. Read the referenced bytes through existing evidence
tools and keep the capture's machine incarnation with the entries. A restore can
include earlier saved inputs in a new machine history; these are retained records,
not newly issued actions in that incarnation. Null means history was not supplied;
count zero with an empty blob means the captured input history was empty.

The frame row's unknown actor does not replace each input's recorded `who`.
The host-owned ledger snapshot remains evidence after new inputs, restore or
package removal. It is a snapshot through the captured cursor, not a claim that
no later input occurred or that an action achieved a strategic game outcome.

Evidence references identify stored bytes. A digest comparison can verify those
bytes; it does not validate an interpretation of the image. Neither this guide
nor the helper opens an evidence URI or issues a game action. A strategic claim
requires separate evidence that supports that claim.

The helper `scripts/summarize.py` accepts the JSON object returned by Lane Inspect
or Slice when it contains `rows` and `coverage`. Select MSX capture rows using
their exact `--row-id` values. The output preserves coverage and original evidence
references while omitting image bytes. A missing selection or a clock that
disagrees with its capture fields is an error, not an empty successful report.
