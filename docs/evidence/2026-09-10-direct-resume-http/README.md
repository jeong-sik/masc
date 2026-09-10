# Real server direct-operation continuation

The CI-built macOS arm64 server at `c202a0f2cf9204e147636bc67a79931741313265` ran against a fresh isolated base on port 18941. Its observed executable SHA256 was `9f6d9fb3f7dc2e7b8f76c1566d8dbbe7879bdcd5847c632c5691627412c414b0`. The downloaded artifact was not release-validated.

The Python provider is an explicitly synthetic HTTP/SSE fault fixture, not an LLM semantic evaluator. Public MCP initialized the session, created a manual Keeper and submitted one message. The primary provider returned the actual advertised Write tool call, then HTTP 429. The alternate provider completed from the saved checkpoint under the same operation and input digest. No Owner runner, checkpoint or journal was injected.

`receipt.json` records the passing assertions: three provider requests, one successful durable Write execution, exact 27-byte filesystem output, one original user and one terminal assistant transcript row. `alternate-admission-semantic.json` captured the real `resuming_runtime_retry` record while the alternate HTTP request was pending. Its checkpoint SHA matches a saved checkpoint in `alternate-admission-checkpoints.json`, and its input digest matches the original running operation. The alternate request preserves the original user input and successful tool receipt. Full provider requests, execution receipt, health and bounded server lifetime log are included; `sha256.json` hashes them.

The harness disables autonomous cycles and Docker preflight using existing fixture settings. The actual native Write producer writes the Keeper's confined Docker playground directory; this does not prove container execution. It proves a real filesystem effect through the production dispatcher and continuation after a provider fault. It does not test whole-process restart, a live commercial provider, or semantic task quality. The earlier setup attempts remain under `/tmp/masc-direct-resume-http-c202-*`; only run 12 is this accepted evidence.

Reproduce without building locally:

```sh
python3 scripts/verify-direct-resume-server.py \
  --binary /path/to/CI/main_eio.exe \
  --expected-commit c202a0f2cf9204e147636bc67a79931741313265 \
  --output /fresh/evidence/path --port 18941
```

The harness rejects an existing output directory, verifies running binary/base identity before submitting work, and stops only its own subprocess. The observation deadline bounds this external probe and does not alter Keeper runtime policy.

Run 10 had a harness observer bug: it checked `.masc/playground/<keeper>` instead of the producer's `.masc/playground/docker/<keeper>` and therefore recorded `effect_exists=false` despite the successful effect. Runs 11 and 12 corrected this path and passed all effect assertions. The harness now derives the observed path directly from the successful tool receipt and requires it to remain inside the isolated base. Run 12 is the sole accepted receipt here; the stale run 10 receipt is not presented as passing evidence.
