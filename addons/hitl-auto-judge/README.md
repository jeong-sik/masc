# HITL Auto Judge worker

This optional package retains original HITL Auto Judge executions. The host owns
the approval queue: the pending approval, the judge original
(`Hitl_judge_original`, retained through `Hitl_judge_owner`), the decision,
terminalisation and consumption. The worker answers a request; it cannot approve,
deny or consume anything, and no provider key or approval state lives here.

It uses the same `addons/exact_worker.py` storage and MCP implementation as the
Workspace Curator rather than a second judgment service. `judge` accepts `submit`
and `read`; only the host-admitted `operator` envelope may submit. The output is
the single Exact output `judgment` (`schemas/judgment.json`, the same schema the
host's `hitl_context_summary_schema` declares). Configure its model under
`runtime.addon_exact_lanes.<installation-id>.judgment`.

The package is a declaration only until the host dispatch is connected: while it
is absent or Off the existing in-process HITL judge keeps running, and the
Required contract and pending approvals are unchanged.

Revision 0.1.1 uses worker record version 2: finished requests retain only the
original ID, digest and result. Existing worker state needs the
[backup and hard cut](../../docs/guides/EXACT-WORKER-STATE-HARD-CUT.md), even when
the host dispatch is not connected. Build its image from the repository root:

```sh
docker build -f addons/hitl-auto-judge/Dockerfile -t masc-lane-hitl-auto-judge:0.1.1 addons
```
