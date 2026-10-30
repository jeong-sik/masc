# Verify a running installed dashboard

After deploying a reviewed release, run the verifier against its installed
binary and the running server:

```sh
python3 scripts/check-installed-dashboard.py \
  --binary /path/to/installed/masc \
  --base-url http://127.0.0.1:8935 \
  --expected-source FULL_RELEASE_SOURCE_SHA
```

The default mode reads files and makes HTTP GET requests. It checks the
expected release source, `/health/ready`, the running executable path and
commit, binary hash, selected installed-release root, receipt hash, served
dashboard index and referenced packaged assets. It prints a JSON receipt
only after all checks pass. Save that output with the release evidence.

This verifies the installed binary and dashboard binding. Verify the runtime
workspace separately through `/health?full=1`, and observe Item balances,
ownership, equipment and portrait behavior in the TUI and browser. A matching
receipt alone does not prove those behaviors or Keeper model decisions.

`--exercise-corruption` belongs to the isolated `scripts/install-smoke.sh`
fixture. It creates a cwd fallback and temporarily corrupts/restores the
installed dashboard and receipt to check failure behavior. Use the default
read-only mode for a live installation.
