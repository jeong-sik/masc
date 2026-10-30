# Apply prepared configuration during an owned restart

The curator candidate needs an additional local provider binding and exact-output
lane. Writing that TOML while the old server is still running can expose it to
configuration its source does not support. The owned integration operator now
accepts a prepared complete TOML and the expected current configuration hash on
`restart-owned`.

Preparation reads regular files without following final symlinks, checks the
current hash, parses the candidate, and resolves the candidate's credential
references before signalling the old process. It does not publish the TOML yet.
The existing operator still verifies the owned listener, PID, source and binary
before SIGTERM. A stop observation timeout retains that process; it does not
replace the configuration or launch a competing server.

Only after the old PID and listener have both disappeared does the operator
record the intended before/after hashes, recheck the original bytes, replace the
TOML atomically with a private same-directory temporary file, fsync and read it
back, and mark the intent applied. The new process starts afterward. This is a
process-interruption recovery record; the operator state writer does not promise
power-loss durability. A failure after configuration rename can leave the new
bytes visible and an unresolved intent. There is no automatic rollback.

An unresolved intent requires an explicit matching replacement and current-file
hash on retry. The actual current bytes must match the retained before or after
hash; the requested replacement must match its after hash. The original intent
is retained until the repeated write/sync/readback succeeds. Do not erase the
intent or retry blindly with different configuration.

```sh
python3 scripts/fusion-decision-live.py \
  --base /path/to/owned-integration \
  --expected-commit VERIFIED_CANDIDATE_COMMIT \
  restart-owned --installed-prefix /path/to/verified-installed-prefix \
  --runtime-config-file /path/to/native-validated/runtime.toml \
  --expected-runtime-sha256 CURRENT_RUNTIME_TOML_SHA256
```

Validate the complete candidate TOML with the candidate native catalog first.
Capture domain state before and after restart, and inspect exact runtime identity,
health, configuration errors, prompt materialization, lane admission and actual
curator behavior separately. Parsing TOML is not native admission. This change
does not grant any Goal approval or demonstrate semantic continuity.
