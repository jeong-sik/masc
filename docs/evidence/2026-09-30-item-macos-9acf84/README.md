# Executed Mac Item server and browser proof

Source: `9acf84d67685af7e958fa08903c6ac722feae228`.
[Manual probe run 36678975675](https://github.com/jeong-sik/masc/actions/runs/36678975675),
job `109770063340`, completed SUCCESS on macos-14 arm64.
`provenance.json` records the workflow and original artifact identifiers/digests.

The native release binaries and production dashboard were built from this
source. The HTTP receipt binds the server binary hash and dashboard index
hash. The server ran over real TCP in a fresh private workspace with two
synthetic paused Keepers. Chromium used actual authenticated API responses.

## Observed behavior

- Desktop detail → Item, retained 360px detail, and fresh 360px document →
  Keeper command menu → detail → Item passed. All three original screenshots
  are included; their hashes match the browser receipt. Page errors: zero.
- The free Keeper bought/equipped glasses, with zero balance and one owned
  item visible. Mobile overflow, runtime-alert width and the command menu's
  lower-edge hit test passed.
- Anonymous account reads were refused. Authenticated MCP rejected another
  wallet argument, unowned equipment, duplicate purchases and insufficient
  funds. No retained call tests an owned item in an incompatible slot.
- A separate paid Keeper started with synthetic 700 milli credit, bought
  crown for 200 milli, and retained 500 milli and crown ownership/equipment
  after a new server process and fresh MCP session.
- The purchased free portrait PNG was identical after restart. Restoring
  default returned the original portrait. Repeated paid equipment and refused
  purchases left the ledger unchanged at those boundaries.
- The original synthetic Paid row is unchanged and exactly one paid purchase
  exists. The final ledger retains the pre-restart prefix and adds only the
  explicitly requested free Keeper default-restoration event.

## Evidence scope

These are actual screenshots of a production bundle served by an isolated CI
native server. They are not screenshots of the operator's installed runtime.
The synthetic credit does not prove a real earned Goal payout or a model's
purchase decision. This run does not prove release installation, runtime
workspace selection, current required PR checks, approval or production rollout.

Raw HTTP/browser receipts, tool-call records, account/portrait responses,
ledger rows and the isolated server log are original artifact files.
`SHA256SUMS` covers those files and provenance; README is explanatory text.

## Downloaded native artifact verification

The separate runtime artifact `11081241355` was subsequently downloaded to a
temporary directory on the operator Mac. All four binary hashes matched its
original `BINARY_SHA256SUMS`. The server hash also matches `http-evidence.json`.
The retained host receipt contains hashes and identity-command results, but
no `file` output; it does not independently prove binary architecture. The server
`build-commit` and TUI `--build-commit` commands both executed successfully
and printed the exact source commit above. The verification receipt and the
original server library-dependency listing are included.

This host check executed identity commands only. It did not start a server,
display a TUI screen, install these files or replace the running instance.
