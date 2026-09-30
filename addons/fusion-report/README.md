# Fusion report

This isolated package turns `fusion-results` outputs into a named `report` port.
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
sequence, upstream rows and coverage, Board post id and host-owned output digest.
A failed run with retained evidence can have complete input while its report
still says failed. Missing evidence, unrelated rows, stale producers and running
runs remain incomplete. Conflicting status/result rows and wrong-run evidence
are rejected.

The worker emits `delivery_status = "not_attempted"`. Use the existing host
Evidence operation to freeze selected report rows and optionally send them to
a Keeper. The resulting accepted receipt proves handoff acceptance; agent
reading or use needs separate evidence. This package never publishes, broadcasts
or infers those later stages. Independent Board edits are visible after the
upstream source is explicitly observed again.

```sh
python3 -m unittest discover -s addons/tests -p 'test_fusion*.py' -v
```

These tests execute both packages over MCP stdio. They prove report projection
and composition under supplied fixtures; Docker isolation and the native
runtime path require their own CI/runtime evidence.
