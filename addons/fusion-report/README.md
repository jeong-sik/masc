# Fusion report

This isolated package turns `fusion-results` or `fusion-compute` outputs into a
named `report` port.
An agent receives the retained analysis body, its run state and the exact input
coordinates rather than row counters. It uses supplied observations only and
does not call a model or fetch a Board card.

Connect the [native Fusion source](../../docs/examples/lane-addons/fusion-live-results.toml)
and [report declaration](../../docs/examples/lane-addons/fusion-report.toml) in the
same run. The report consumes the producer's whole output so that both status
and retained result are present. A selected `result` port also works, carrying
the producer's whole coverage. A status-only source yields an incomplete report
until evidence is present. Multiple runs produce independent reports.

The Markdown body contains copied Board evidence, treated as untrusted source
text. It is not a new judge decision. Typed fields retain `run_status`,
`input_complete`, producer configuration/package revisions and observation
sequence, exact upstream row coordinates and coverage, Board post id and the
host-owned immutable output digest. The full upstream row payloads remain
readable through that output evidence; the report keeps the analysis body once.
One `fusion/report-context` row retains producer coordinates, whole input
coverage and exact upstream row references for each observation. Each
`fusion/report` row links that context through `related_ids`. The named `report`
port includes both lanes, so selecting it preserves the evidence relationships
without copying shared provenance into every run's report. Context rows carry
metadata and have no analysis body; presentation reads the report lane only.
A failed run with retained evidence can have complete input while its report
still says failed. Missing evidence, unrelated rows, stale producers and running
runs remain incomplete. Conflicting status/result rows and wrong-run evidence
are rejected.

For assembled computation, connect a panel or judge's named `result` output.
The report preserves actual role/status/model/free-text reply, original sampling
response/error, model request/outcome references, and input coverage. It does not
create a Board post or native Fusion run. Known failed outcomes can have complete
evidence while remaining failed; request-only `outcome_unknown` stays incomplete.
The [assembled examples](../../docs/examples/lane-addons/fusion-compute/) connect
two panels to a judge and then this report package.

The Markdown body also shows the declared report input, its producing
installation/run/instance and completed observation, and the retained coverage
details at each supplied boundary. Partial input reasons remain visible beside
the analysis. A next-step section distinguishes an answered call, host failure,
an uncertain outcome and a rejected response. These are reading guidance from
recorded states; the package does not retry a call, repair an input or act for
the receiving agent.

Computed reports reference one `fusion/report-context` row per upstream
observation. It retains exact original computation rows in `raw_computed_rows`, Native
row coordinates in `upstream_rows`, producer coordinates, coverage and
immutable output evidence; the report body remains complete. The named `report`
port includes both report and context, so related evidence stays available.
MCP text summarizes the structured output. Replies exceeding the manifest's
declared envelope are refused without accepting a shortened report.

The MCP text content is a short summary; structuredContent carries the complete
report. The worker checks the serialized UTF-8 reply against the manifest's
declared envelope and explicitly refuses an oversized reply without truncating
the analysis body or accepting incomplete output as a successful report.
The results producer permits a 4 MiB reply. The report allocates 8 MiB for the
full retained body plus Markdown and host provenance; both packages enforce
their own manifest limits. Additional provenance can still exceed the report
allocation and is refused explicitly.

Native Fusion Board posts carry a short headline in `body`. Reports render that
headline separately and read the analysis from canonical `meta.judge.resolved_answer`.
The canonical judge states are `synthesized` and `failed`; missing or malformed
judge metadata is refused. Structured synthesis remains in the retained original
source, reachable through the report context's immutable output digest. Run failure,
judge failure, incomplete input and delivery remain separate observations.
The worker emits `delivery_status = "not_attempted"`. Use the existing host
Evidence operation to freeze selected report rows and optionally send them to
a Keeper or explicitly Broadcast it. A Keeper accepted receipt proves handoff acceptance; agent
reading or use needs separate evidence. This package never publishes, broadcasts
or infers those later stages. Independent Board edits are visible after the
upstream source is explicitly observed again.

```sh
python3 -m unittest discover -s addons/tests -p 'test_fusion*.py' -v
```

These tests execute the packages over MCP stdio. They prove report projection
and composition under supplied fixtures; Docker isolation and the native
runtime path require their own CI/runtime evidence.
