# MASC agent core

This directory owns MASC's typed single-agent execution engine: provider
protocols, turn execution, tool dispatch, checkpoints, and telemetry.

It is part of the `masc` package and is published only as the
`masc.agent_core` OCaml library. It has no independent opam package, release
version, compatibility policy, or repository-level CI.

The dependency direction is intentionally one-way:

```text
MASC coordinator/runtime -> masc.agent_core -> external protocol libraries
```

Code below this directory must not import Keeper, Board, Gate, Server,
Operator, workspace, or runtime-configuration modules. The enforced boundary
is `scripts/check-agent-core-boundary.sh`.

The current OCaml facade remains `Agent_sdk` while callers are migrated in a
separate, reviewable hard-cut change. That module name is not an external SDK
compatibility promise.

Verification:

```bash
dune build --root . @packages/agent_core/test/runtest
bash scripts/check-agent-core-boundary.sh
bash test/test_agent_core_boundary.sh
```
