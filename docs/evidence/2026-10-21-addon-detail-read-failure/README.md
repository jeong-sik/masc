# Native detail-read failure and Evidence interleaving

This is a bounded manual observation of frozen source
`2c0e4abaf3322f2d9a4ed9e336b4cd230b4da1fd`. It is not execution of the later
restacked `321efcb` candidate, full54 completion, operator deployment or release proof.
The separate [repaired lifecycle evidence](../2026-10-21-addon-repaired-native-ui/README.md)
belongs to source15478 and is not relabelled as this run.

## Actual executable and setup

Native run [39607780651](https://github.com/jeong-sik/masc/actions/runs/39607780651)
produced matching server/TUI executables and selected 23 TUI +5 application checks.
The original receipt, selected targets, logs and independent file-hash/embedded-commit
observations are preserved here. These checks passed on source2c, not on a new base.

The actual server ran in an isolated workspace with the declaration Off and two
retained, released workers from the earlier synthetic lifecycle observation.
The TUI and server binary identities match the native receipt. No operator server,
profile, browser, provider or live installation was replaced.

The raw forwarding proxy is a manual transport fault mechanism, not a mocked server.
Only selected Slice connections were closed, without returning an HTTP response.
Inventory, asks and the actual Evidence POST were forwarded to the matching backend.
The backend independently returned HTTP200 and actual retained rows during this fault.
An initial helper mistake forwarded the proxy Host and caused HTTP400; the helper was
corrected to use the backend authority. Captures01/02 retain that unsuccessful setup.
The final helper sources document the forwarding and fault selection. Paths and
ports are historical observation coordinates, not product configuration defaults.

## Observed sequence

1. Captures04–07 opened the actual Add-ons pane, selected retained owner
   `01a15e9c-7fad-7000-937e-b01fd76c5e1c`, read its original `repaired-input-1`
   stop_requested row and marked that row. The other retained worker is distinct.
2. Capture08 followed a manual refresh with the controlled Slice connection fault.
   Fresh inventory still read successfully. The original row, its evidence reference
   and selection stayed visible with a detail-read failure and an explicit retry.
3. Captures09/10 preserved that row through the real Evidence endpoint while the
   Slice fault remained active. The returned receipt names the original owner/row
   and SHA256 `5e53bdbf58afc23bcb4674e2f0e5aa7c8ef1b48a75b076074277ea07bd9a1de4`.
   The actual server-created artifact is included. The new receipt and original
   read failure coexist; no Broadcast or message sharing was selected.
4. Capture12 submitted invalid command input. Its separate input diagnostic did
   not erase the retained row, Evidence receipt or detail-read failure.
5. Capture13 followed removal of the fault and a refresh. A successful original-run
   read cleared the failure while preserving the row, selection and Evidence receipt.
6. Capture14 requested the same run with a deliberately unmatched lane filter.
   A real successful empty result replaced the prior rows, and the receipt remained.
   Capture15 returned to the full run query and recovered the original row.

`transport-events.jsonl` records request method/path/forward-or-close decision only.
It shows repeated automatic inventory and scoped Slice requests between manual
commands, including failures while the pane was idle. These events prove requests
were issued; they are not response latency measurements. The explicit full/empty
backend responses, terminal stream, commands and selected cell captures remain separate.

## Integrity, cleanup and remaining limits

The terminal stream is actual child output. PNGs are diagnostic renders of preserved
160×56 VT cells, not physical desktop screenshots. No product screen assertion,
layout golden test or simulated HTTP response was introduced. UI observations are
manual evidence rather than an automated presentation verdict.

The declaration remained Off. The exact original containers were absent at final
inspection. Owned server3632, TUI4307 and corrected proxy82104 were stopped; process
and refused-port observations are recorded separately from shutdown requests.
Credentials, private login files and private server logs are excluded. The manifest
hashes every selected public file and decompressed bytes for gzip files.

Known separate P2: an advanced Slice for another run can still be classified as
the original Detail success by the current source. That scope-admission finding is
under repair; this successful same-run sequence does not clear it. HTTP200 partial
store-read semantics, owner replacement, all workspace races and every provider or
device recovery class are also not established by this sequence. Synthetic phrase
state is not real audio/VST output or audibility proof.
