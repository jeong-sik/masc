# Executed JSONL retention and configuration boundaries

Reviewed baseline: `2b230357cb72586fe0c20d5a07490a43cb93ecab`.
Product carrier before this cycle: #41096 at
`140d649e275c61ce3ff1e02bab0a9d0507b2c6a1`.

The complete registered `test_metrics_rotation.ml` suite ran unchanged against
isolated copies of the complete production Fs_compat and Env_config_keeper
modules and the exact production JSONL rotation/append and UTF-8 repair code.
All 24 cases pass: twelve scenarios each under real Stdlib and Eio filesystem
paths, using temporary directories. The same suite has ten failures against
the baseline. The cases include zero/reduced retention, unrelated names,
live/dangling symlinks, directory refusal and disabled rotation.

The real Keeper_runtime_config loader and typed setting registry were also
compiled natively. Three further checks pass through real temporary TOML and
actual file appends: zero retention is applied/effective and removes backups;
process env overrides TOML and retains the requested two backups while pruning
excess files; negative TOML retention is rejected at boot validation.

## Setting scope correction

Tracing the consumers found that these settings govern auxiliary JSONL logs
(decision, response feedback and runtime manifest paths), not the separate
Dated_jsonl metrics store used by turn/heartbeat snapshots. The typed setting
registry now identifies Keeper_types_support.append_jsonl_line and labels
that scope; ENV-CONTRACT and the accessor documentation match it. This change
does not establish retention for the date-sharded metrics store.

## Reproduction and boundaries

Run `python3 check-metrics-native.py CHECKOUT CACHE_CHECKOUT` with an existing
OCaml 5.5.1 dependency cache. It prints an isolated run directory; then run
`python3 check-metrics-boot.py CHECKOUT CACHE_CHECKOUT RUN_DIRECTORY`.
The scripts compile selected production modules directly and read cached
dependency objects. They do not invoke Dune or alter the shared cache. Test
aliases bind the unchanged suite to isolated module copies; no filesystem or
configuration behavior is replaced by a mock. JSONL writer functions are
source slices, so this is not a complete Keeper/server binary build.

The boot probe is separate from the registered whole runtime-TOML suite, which
has not been run. No full CI, installed-candidate, HTTP/PTY, runtime restart or
deployment evidence is claimed. Independent current-head review remains pending.
Source hashes and raw results accompany this note.
