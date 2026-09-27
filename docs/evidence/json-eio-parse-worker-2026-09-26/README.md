# Large verification JSON reads and scheduler availability

## Observation

The running server identified itself before and after the read-only probe as
commit `4bd0eedad058ed37c0e374b157014b5eee6c654f`, executable SHA-256
`9726d2bb7c3a675fdfcdd319928cd0669a0e9428e7d77f06f5f3ef0cc4d863c9`, instance
`01a0dd3f-c319-7000-be50-9dd9ce916f9e`. No server restart or deployment was
performed for this observation.

`cpu-sample-excerpt.txt` retains exact excerpts of a three-second macOS
`sample` at a 1ms requested interval. The main thread includes Yojson string
parsing, UTF-8 validation and `Safe_ops.read_json_eio`. Normal Keeper work and
80 sequential execution GETs ran during sampling. Samples are not per-request
timings and do not attribute all observed JSON work to this helper.

`verification-file-sizes.json` is an aggregate of file metadata, without
document contents or filenames: 1,864 verification JSON files total 61,519,175
bytes; 97 are at least the existing 131,072-byte parse-offload boundary,
totalling 38,777,582 bytes. The largest is 1,429,161 bytes. This establishes
that this reader's actual store contains documents above that boundary; it
does not establish which files the sample caught.

## Source change

`Verification.load_request` and the verification store's evidence and
cancellation-reason readers use `Safe_ops.read_json_eio`. Their file read may
yield, but the subsequent `parse_json_safe` ran on the calling domain even for
large documents. `read_json_file_safe` already uses `parse_json_off_fiber`.

The change routes `read_json_eio` through that same policy. It adds no cache,
threshold, pool or data truncation. Existing worker/non-Eio/no-pool fallbacks
apply. Queueing, total parsing CPU and global GC costs remain; this change
does not establish an end-to-end latency improvement or the 0.1ms objective.

## Behavioral proof to execute in CI

`test_safe_ops_read_json_eio` holds the sole CPU worker and reads real
synthetic files. Filesystem registration is cleared temporarily so those
fixture reads cannot suspend before parsing. Thus the old inline parser would
complete before the admission assertion; the new large parser waits for the
worker while a small Unicode read and another fiber complete. Releasing the
worker must yield the exact large document.

The same scenario covers invalid UTF-8 with exact repair statistics and
malformed JSON with the existing empty-object result. The test restores the
filesystem and pool references and releases the held worker on failure. Its
ten-second deadline is a test deadlock backstop, not a response-time target.

Static parsing, diff whitespace checks and test-function registration pass.
No local OCaml build was run. CI results are pending.
