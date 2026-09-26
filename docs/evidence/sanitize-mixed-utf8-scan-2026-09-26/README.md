# Multilingual sanitization scan

## Finding and change

An owned, isolated server profile showed calls through
`Safe_ops.sanitize_json_utf8` → `sanitize_text_utf8` → `has_invalid_or_control`.
The whole-process leaf table recorded 108 self samples in
`has_invalid_or_control` and 394 in the UTF-8 decoder. **The decoder also runs
under `Format.width` and other callers**; all 394 are not attributable to this
sanitizer. Most samples across the process's many threads were waiting. These
counts are an investigation clue, not percentages of request latency or proof
that this sanitizer dominates the first HTTP response.

The source first scanned for clean ASCII. Upon meeting any non-ASCII byte it
restarted validation at offset zero and decoded every subsequent scalar,
including ASCII, through `String.get_utf_8_uchar`. The replacement makes one
validation traversal: direct control-byte checks for ASCII and the existing
standard decoder for non-ASCII. It returns the original clean string. On the
first invalid byte or disallowed control, it copies the already validated
prefix once and starts the unchanged repair loop at that byte.

LF/CR/TAB remain allowed, other ASCII controls become spaces, and invalid UTF-8
is still replaced one byte at a time. No decoder, invalid-byte policy, cache,
rate-limit setting, timeout, interface, shared state or concurrency primitive
is added. This change affects writer-side persistence and broadcast string
sanitization, used by the MCP workspace and server. It is not a bypass of
validation and does not change read-path repair statistics.

## Native profile and incomplete workload

- Source `887807abe0bfb2b3d2df7fbca7672faa199aa898`, runtime artifact `10905529982`
  from [build 36241015541](https://github.com/jeong-sik/masc/actions/runs/36241015541).
- Server SHA-256 `1d0eb19346c7b1663076a44af5c93a9a5d446bcb0c8d56cedcb76ebac81928fa`.
  It predates this sanitizer change. The artifact's source/run/repository and
  all binary hashes, live executable identity, isolated root and zero Keeper
  fibers were checked by the retained runner. It is not release validation.
- Exact sampling command: `/usr/bin/sample 6424 5 1 -file <output>/native-sample.txt`.
  The requested interval was 1ms over five seconds. Sampler PID 6726 completed
  with exit 0 and was reaped; `sample-command.log` records completion.
- The synthetic workload seeded 250 tasks, then planned 300 cycles of real
  MCP add-task followed by first/warm execution GETs. The **243rd add-task
  returned HTTP 429**, `Per-agent rate limit exceeded`. The workload exited 1;
  242 successful cycles and 484 GET observations are retained. This is not a
  full-workload pass. No retry or rate-limit configuration change was made.
- The profile interleaves MCP mutations, broadcasts, first and warm GETs,
  filesystem work and normal background fibers. The backlog grows during the
  run. Neither stack samples nor profiled timings isolate HTTP GET cost.
- The observer omits retaining every large parsed response, unlike the paired
  first-response experiment in #39303. These profiled timings must not be pooled
  with that experiment or presented as a before/after performance result.
- Owned server PID 6424 exited 0 and was reaped after the workload failed. Both
  server and sampler PIDs were absent when checked. The separate cleanup status
  does not change the workload failure. A single model-list GET hit the owned
  loopback stub; no generation or production operation was requested.

`native-sample.txt.gz`, `observations.json.gz` and `setup.json.gz` losslessly
retain the raw collected files. `profile.json` is unchanged and has no workload
finished timestamp because the run raised before assigning it. The separate
`workload-outcome.json` records the terminal tool receipt and its source.
The exact runner, identity and SHA manifest are retained. Server logs and the
isolated runtime directory are not published. No real user data is used.

## Verification and limits

- Inspected installed OCaml 5.5.1 `bytes.ml` (`get_utf_8_uchar`) and `string.mli`:
  ASCII bytes decode independently; non-ASCII validation still uses that same
  decoder. The source's original malformed-decode handling advances one byte,
  including when a malformed decoder result reports a longer length; the repair
  loop preserves this behavior.
- Added a multilingual JSON scenario covering physical reuse of clean JSON,
  every isolated byte 0–255 between complete Korean scalars, truncated, overlong,
  surrogate and out-of-range sequences, and controls in nested keys and values.
  The test oracle specifies results rather than copying the old validator.
- Existing safe-operations and repair-statistics tests remain. No local OCaml
  build was performed. Syntax parsing passed with ocamlformat; existing
  unattached-documentation warnings required `--no-comment-check` for safe_ops.
  Files were not reformatted. Whitespace checks passed.
- Independent adversarial review found no semantic or ownership defect. The
  response review and CI results are recorded in the PR body when available.

A separate [paired comparison](comparison/README.md) now measures 480 Task
acknowledgements and 960 GETs across ASCII and multilingual descriptions.
Multilingual mutation medians were lower in all three repetitions for each GET
encoding, while ASCII/identity mutation median and multilingual/identity first
GET median worsened. All observations, actual persisted backlogs and mixed
results are retained. These are whole HTTP round trips, not isolated sanitizer
CPU time. No general speedup, allocation-volume result, deployment, TUI
improvement or 0.1ms achievement is claimed. The original native profile remains
a separate, incomplete-workload observation.

## ASCII predicate follow-up

The measured candidate has a per-ASCII-byte predicate call that the earlier
ASCII scan did not have. [Exact artifact disassembly](ascii-call/README.md)
records that operation without attributing the timing regression to it.
A later source change requests inlining of the existing pure predicate. It is
not part of the paired result above; its emitted code and performance need a
new artifact and comparison.
