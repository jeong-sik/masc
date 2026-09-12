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
descriptor names `msx-input-jsonl-sequence`, the exact entry count and a
`lane-sequence:SHA256` root. Its count matches `fields.input_cursor`. Each immutable
node has schema `masc.lane-jsonl-sequence.v1`, `entry_count`, `record` (one JSONL
record preserving native `frame`, `who`, `key` and `edge`), and `previous` (another
sequence evidence reference). New captures share the unchanged prefix; they do
not copy all earlier inputs.

Select Lane Evidence and use the published artifact manifest's `artifacts` to
map each `lane_uri` to its Keeper-readable artifact. Read that artifact through
`keeper_artifact_read`; do not turn a Lane URI into a filesystem or network path.
Starting at the selected root, verify each digest and schema, require the count
to decrease by exactly one, and follow `previous` using that same manifest. Count
zero must have null `record` and `previous`. Reverse the collected records to read
inputs in their original order. A missing node, count mismatch or unsupported
schema means incomplete evidence, not an empty history. The published manifest
contains the entire selected chain, so reading it does not require an attached
observer or access to the Lane store.

Keep the capture's machine incarnation with the entries. A restore can include
earlier saved inputs in a new machine history; these are retained records, not
newly issued actions in that incarnation. Null means history was not supplied;
count zero with a valid empty sequence root means the captured history was empty.

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
