# Role prompt evidence — 2026-09-08

[Design and sources](../../design/role-prompting-2026-09-08.md) describe the selected approach.

## Static contracts

`contracts.json` compares the six changed Markdown assets against source base
`c62f10f74b`. Frontmatter, template-variable sets, slot names and slot variable
contracts are unchanged. Librarian output keys, category order, ID partition and
supersedes constraints remain. `git diff --check`, prompt path validation, and
Python compilation of the probe passed. Local Dune builds were not run.

## Model probe

The five synthetic cases were fixed before the model calls: operator constraint
retention, fabricated permission exclusion, relevant Board signal, unrelated
Board prompt injection, and evidence-free panel consensus. `before.json` and
`after.json` contain the model's visible answers and exact rendered prompt hashes.
Both versions passed 5/5 on `glm-coding.glm-5.3-flash`, resolved from the operator's
existing runtime configuration. This is regression smoke evidence, not a measured
improvement in judgment accuracy or a model-selection benchmark.

The probe reuses `scripts/memory_os_judge_eval.py`'s direct HTTP transport. It does
not execute MASC's native schemas, decoder, CLI fallback, retry flow or tools.
The singleton Board JSON and memory rows are synthetic fixtures, not runtime
captures. The empty system message is a transport approximation. Fusion receives
no configurable judge system prompt or web tools here. The pass predicates check
selected outcomes, not every output invariant. No live Task, approval or memory
was changed. Task/Goal/effect judgments are not covered by these model cases.

Reproduce after configuring the desired provider credentials in the environment:

```sh
python3 docs/evidence/role-prompts/probe.py \
  --runtime-config /path/to/runtime.toml \
  --runtime-id provider.model \
  --prompts config/prompts \
  --output /tmp/role-prompts.json
```

`--runtime-id` is explicit: no model cascade or fallback can silently change what
this probe measures. To reproduce the before result, materialize the same prompt
files from `c62f10f74b` into a temporary directory and pass it with `--prompts`.

After review, the Librarian privacy exclusion was restored to its original
unconditional scope. `after-librarian-final.json` reruns the two affected memory
cases against the final text; other role prompts are unchanged from `after.json`.

## Deployment boundary

`live-sources.json` records a read-only snapshot of effective prompt sources on
port 8935 for the `/Users/dancer/me` runtime. It records hashes, not private input.
These role prompt changes have not been applied to that live runtime. Asset
installation, override precedence, actual model inputs and end-to-end judgments
must be verified at deployment. A source diff and a green CI do not prove them.
