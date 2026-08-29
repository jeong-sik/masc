# Coding-outcome baseline, docker substrate — 2026-08-29

Same case, model, and approval stance as
[`../20260829-ungated`](../20260829-ungated/NOTES.md); the execution
substrate moves from the deprecated local playground to the docker sandbox
(`sandbox_profile = "docker"`, image `masc-keeper-sandbox:local` present on
the host).

## Result

**pass@1 = 1.00 over n=2 (`min_runs_met=false` — below the n≥5 gate).**

| Run | Outcome | verify | Duration | Tool calls |
|---|---|---|---|---|
| 1 | completed | 0 (green) | **14s** | 4 |
| 2 | completed | 0 (green) | 81s | 6 |

Fastest episodes so far (local substrate: 117s/95s). One prior single probe
run on this substrate scored 0/1 — the model quit after three root-level
path misses — which reads as small-model variance, not substrate failure:
the very next collection went 2/2.

## Substrate notes

- A docker keeper's working root is `<playgrounds>/docker/<name>/`
  (`keeper_sandbox_config.host_root_rel_of_profile`) — the profile segment
  keeps lanes from finding each other's trees. The harness materializes the
  case workspace inside that root; the local-profile path
  (`<playgrounds>/<name>/`) is invisible to the container.
- Wrinkle observed, not yet filed: `Grep` with `cwd: "."` returns
  `path_outside_sandbox: .` under docker where the local profile resolved
  it — worth a typed look if it recurs in W3 runs.

```bash
scripts/harness_coding_eval.sh --models "ollama:qwen3:8b" \
  --case-ids l1-calc-add --repeats 2 --out <dir>
```
