# Coding-outcome baseline, W3 corpus — 2026-08-29

First collection over the expanded corpus (RFC-0396 W3): 7 cases across
three levels and three languages, docker substrate, `ollama:qwen3:8b`.
L1 collected at n=5 (the RFC's "fill n≥5 from L1 first"); L2/L3 at n=2
smoke depth, honestly below the `min_runs_met` gate.

## Result

**9/23 runs verify green (39.1%). Zero timeouts, zero provider or
transport errors** — every episode completed and every verdict is the case
verify script's own exit code. The infrastructure layers that dominated the
earlier collections are fully out of the way; this distribution measures
the model on this tool surface.

| Case | Level | Lang | pass@1 | n |
|---|---|---|---|---|
| l1-bash-classify | L1 | bash | 0.00 | 5 |
| l1-calc-add | L1 | python | 0.20 | 5 |
| l1-node-sum | L1 | node | 0.80 | 5 |
| l2-node-stats | L2 | node | 1.00 | 2 |
| l2-py-slugify | L2 | python | 0.50 | 2 |
| l3-py-config-plumb | L3 | python | 0.50 | 2 |
| l3-py-rename-callers | L3 | python | 0.00 | 2 |

Tool calls across all 23 episodes:

| Tool | ok | failed |
|---|---|---|
| Execute | 51 | 2 |
| Read | 27 | **14** |
| Edit | 16 | **7** |
| Write | 9 | 0 |
| Grep | 3 | 2 |

## Observations

- **Edit misses run at 30%** (7/23 calls) and several episodes fall back to
  whole-file `Write` after an Edit miss — the measured justification for
  RFC-0396 D6-1 (edit failure diagnostics). Read misses run at 34%, almost
  all relative-path probing before the model finds the workspace — the same
  number D6-4 (navigation/outline) starts from.
- **Fix-a-bug is harder than write-from-spec at this model size**: both L2
  implement-a-function cases outscore two of the three L1 bug fixes. The
  worst case, l1-bash-classify (0/5), is instructive: the model flipped the
  buggy branches correctly and then *added an unrequested pwd guard that
  `exit 1`s under the check*, breaking every run — over-editing, not
  misunderstanding.
- l3-py-rename-callers (0/2) fails the way L3 is meant to probe: the fix
  requires coordinating an edit with a contract read from a second file.
- Same command, same case, different day: l1-calc-add scored 2/2 twice
  yesterday and 1/5 here. Small-model variance at n≤5 is large; `pass@k`
  with `min_runs_met` says exactly this, which is why per-case verdicts
  below n=5 are smoke, not conclusions.

```bash
scripts/harness_coding_eval.sh --models "ollama:qwen3:8b" \
  --case-ids "l1-calc-add,l1-node-sum,l1-bash-classify" --repeats 5 --out <dir>
scripts/harness_coding_eval.sh --models "ollama:qwen3:8b" \
  --case-ids "l2-py-slugify,l2-node-stats,l3-py-rename-callers,l3-py-config-plumb" \
  --repeats 2 --out <dir>
```
