# Keeper prompt-cache observation, 2026-11-01

- Baseline source: `e49cce0508d5e3f5b740abdd01f217b3efc8f6ba`.
- Collector: the changed `scripts/analysis/prefix-cache-first-round.py`, SHA-256
  `7808e2cc7852c79c43a7f888f785497ce4a7d1ce95ac3e23174bd8f473bf68d1`.
- Captured at: `2026-11-01T03:51:33+00:00`, UTC date `2026-11-01`.
- Keeper: `code-reviewer-father`, runtime `glm-coding.glm-5-3`.
- [measurement.json](measurement.json) contains only metadata and hashes; no
  prompt, message, tool-result or credential text is retained in this bundle.

The local collection used the running server's effective workspace root. A new
run can be collected under `artifacts/` using the deployment's actual root:

```sh
python3 scripts/analysis/prefix-cache-first-round.py \
  --masc-root /path/to/workspace/.masc --date 2026-11-01 \
  --keeper code-reviewer-father --read-system-prefix \
  --output artifacts/prompt-cache-measurement.json
```

Each source file is read once; files are not captured atomically with each other.
The source byte counts and digests identify the sampled versions. System blobs
are checked against their retained byte counts and SHA-256 before comparison.
There were 5 prepared snapshots, 4 consecutive pairs, 10 turn records and 43
per-request raw usage rows; no malformed records or blob failures were observed.
No deployment split was supplied; `sample` is not a before/after benchmark.

The 300→301 pair retains a 125,705-byte prefix of a 125,780-byte System; all four
pairs retain identical tool schemas. The last reported request for turn 301 has
89,879 input tokens and 85,696 cache reads. Across the ledger sample, median
missed input is 24.9% on first observed requests and 1.1% on later requests.

Prepared snapshots prove serialization, not provider acceptance. Their turn
records do not bind a response to a capture digest, so turn usage is shown
separately. Raw prefix bytes are not tokenizer counts or proof of actual KV
reuse. First observed requests may omit earlier requests outside this sample.
No running Keeper, prompt override, model or server was changed for collection.
No new TUI binary or latency improvement was measured.
