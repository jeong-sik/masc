# Manual macOS arm64 runtime artifact

Use `.github/workflows/linux-x64-probe.yml`, target `macos-arm64`, for an
isolated native artifact. The macOS 14 job uses the shared OCaml setup and
release dependency pins, builds the four runtime companions, and calls
`scripts/package-macos-runtime.py` with the release asset filenames. It does
not create a release, tag, installation, or provider request. The packager
downloads pinned Python and checks HTTPS certificate discovery; these are
packaging network checks, not model calls.

The artifact is named `macos-arm64-probe-<full-source-sha>-attempt-<attempt>`
and retained for seven days. It contains the five `*-macos-arm64` executable
assets, `masc-runtime-macos-arm64.tar.gz` (libraries, Python, licenses and
runtime provenance), `SHA256SUMS`, identity outputs, `dependencies.txt`, and
`probe.json`. Checksums cover the final packaged files and metadata.

The workflow change is tracked in main-based PR #40205. For a Home
branch artifact before merge, integrate that dependency and then:

1. Apply this workflow change and this runbook to the Home branch, preserving
   its Home implementation and tests. No packaging helper changes are needed.
2. Commit and push the integrated Home branch under the parent's authorization.
   Dispatch **Manual probe artifacts** on that branch with target `macos-arm64`.
3. Compare the run's `head_sha`, artifact name, `probe.json.source_commit`,
   `runtime-provenance.json.source_commit`, and `tui-build-commit.txt` with the
   full Home head SHA. A later Home change requires a new artifact.
4. Download the successful artifact into an isolated directory and verify
   `shasum -a 256 --check SHA256SUMS`. Extract the runtime archive there, then
   copy each executable asset to its suffix-free name beside `lib/` and
   `python/` (for example `masc-tui-macos-arm64` to `masc-tui`), then explicitly run `chmod +x masc masc-tui masc-browser-host
   masc-deployment-preflight-helper masc-check-runtime-deployment-preflight`
   because downloaded artifacts do not retain executable bits. Run `./masc-tui --version` and
   `./masc-tui --build-commit` before the parent's isolated Home scenarios.

The CI identity checks load the packaged TUI without a TTY or server and
compare its version with the server companion and its commit with the run SHA.
The packager also audits relocated native dependencies and exercises staged
bytes with Homebrew roots unreadable. This is packaging and identity evidence;
Home behavior, baseline comparisons, and current-head merge checks remain the
parent's responsibility. No dispatch or artifact production is implied by
static workflow validation.
