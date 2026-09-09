# Keeper groups followed by workspace synthesis

`curate-workspace-memory.py --workspace-pass` processes the captured server
inventory in its canonical Keeper groups. Every Keeper gets its own input with
its original source IDs, ordinary/source-bound snapshots, retractions and gaps.
There is no numeric batch cap. Keepers with gaps but no source claims are recorded
without a model call. After all groups succeed, a final model call compares their
proposals across owners using the complete original source attribution index.

The final artifact retains every original source, snapshot and collection gap.
Both group outputs and the final output must account for their complete source
set through citations or explicit exclusion. A failed group or incomplete final
coverage produces a failed run without a final proposal or publication. Coverage
is structural; it does not prove semantic correctness of the model's summaries.
Synthesis starts with group proposals and attribution. It can return a typed
`read_sources` action naming original IDs; the next request includes those exact
original sources and referenced snapshot metadata. This lets it reconsider
excluded claims and inspect retractions without resending the full corpus. It
returns `final` only when ready to produce the complete proposal. Every lookup
and subsequent request/response is saved under `synthesis/`; no numeric lookup
cap or automatic retry is introduced. Stored evidence is not independent fact
verification.

```sh
uv run scripts/curate-workspace-memory.py \
  --context /path/to/captured-context.json --workspace-pass \
  --endpoint http://127.0.0.1:11434 --model installed-local-model \
  --output /path/to/first-run
```

Each run has a fresh output directory. `plan.json` binds captured-context SHA-256,
model name/digest/origin, group requests, original source IDs and synthesis
instructions. `groups/keeper-<digest>/` records requests, raw streamed responses,
results, progress and model receipts. `synthesis/` records the final pass. Group
folder names derive from Keeper identity hashes instead of filesystem paths
supplied by a Keeper. The top-level token/count measurements describe the final
synthesis completion request; each group and synthesis request retains its own
measurements in its model receipt.

An explicit resume can reuse completed groups while preserving the old run:

```sh
uv run scripts/curate-workspace-memory.py \
  --context /path/to/first-run/context.json --workspace-pass \
  --resume-from /path/to/first-run \
  --endpoint http://127.0.0.1:11434 --model installed-local-model \
  --output /path/to/resumed-run
```

Every run holds a POSIX OS file lock throughout capture, inference and optional
publication. Resume must first acquire the previous run's lock nonblockingly. An
active owner is refused without inference; a persisted `running` status or elapsed
age never proves that work stopped. The lock is released by the OS on process
exit. Resume checks exact captured bytes and the model/plan binding, then validates
completed requests, result/response hashes and source coverage before copying
known evidence files into the new run. Failed or interrupted groups run again;
completed groups are not inferred again. Synthesis is performed after all groups
are available. A newly fetched context may have a different timestamp or content;
use the captured `context.json` when resuming the same work. Resume is an explicit
operator action, not an automatic timer or retry loop.

Every inference request sends `truncate: false` and `shift: false`, fields defined
by [Ollama v0.33.3's `ChatRequest`](https://github.com/ollama/ollama/blob/v0.33.3/api/types.go#L121-L156). `/api/ps` is captured before/after inference as
an observation; empty loaded-model lists or unavailable observation endpoints do
not gate the task. No context-size default or output/time budget is introduced.
An oversized individual Keeper group or synthesis still requires the provider to
handle or reject it; grouping does not prove that every possible request fits.

Validation: 20 CLI scenarios passed, including the existing source/publication
scenarios and local HTTP workspace-pass scenarios for cross-Keeper synthesis, original ID
preservation, metadata-only evidence ownership, gaps-only Keeper handling,
original-evidence lookup before emitting a cross-Keeper conflict, partial
failures, resumable completed groups, binding mismatch, tampered checkpoint
rejection, unknown source lookup refusal and a concurrent live-owner lock test. Real full-corpus inference, semantic correctness and
publication from this mode remain unmeasured in this change. No private workspace
memory contents are included here and no local build was run.

## Full-corpus input measurement

`full-corpus-tokenizer-receipt.json` records the installed Ollama 0.33.3 render
and runner-tokenizer observation. The pinned implementations are
[Chat render](https://github.com/ollama/ollama/blob/v0.33.3/server/routes.go#L2776-L2817)
and [runner tokenization](https://github.com/ollama/ollama/blob/v0.33.3/llm/llama_server.go#L2320-L2369). The render response retained the exact complete
user payload. Its 1,441,462 rendered bytes tokenized to 518,293 tokens with
`add_special: false, parse_special: true`, exceeding the loaded context of 262,144
tokens. The runner's model weight hash matched a model source reported by
`/api/show`. This supports splitting work at Keeper boundaries rather than sending
the entire inventory in one request.

This observation did not run inference and does not prove prefill acceptance,
absence of truncation during inference, summary correctness, or whether each
Keeper group/final synthesis fits. Only aggregate receipt metadata is committed;
the rendered prompt, token list and private memory inventory remain outside Git.
