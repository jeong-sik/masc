# Queue and retained image execution evidence

Executed source: `cf6a0c37b52ce0a05ad4b717a4e98585c4cde131` (2026-10-01 KST), the parent of this evidence commit. Subsequent evidence/changelog edits do not claim a new executable run.

The operator explicitly authorized an isolated TUI build and Queue/image PTY verification. No installation, server restart, production session changes or CI dispatch occurred.

## Executable and results

Build: `opam exec --switch=5.5.1 -- scripts/dune-local.sh build bin/masc_tui.exe test/test_tui_image_preview.exe`, exit 0 in 179.33s. The wrapper and dependency guards ran without a bypass. See `build.log` and `build-result.json`.

TUI SHA256: `3a1b674315ebd4cb59649f7cbc453e1ab497ac4a314dc86ffc17180e3bd54699`.

| Executed scenario | Result | Scope |
|---|---|---|
| Queue PTY | PASS, 13.42s | Local input, POST, server acceptance, 80-column mixed queue, Keeper navigation, reconciliation and accepted→disconnect→same-ID reconnect→RUN_STARTED with terminal response held |
| Retained image PTY | PASS, 13 modes, 25.04s | Saved image, HTTP refusal, malformed/missing envelope, wrong digest/length, corrupt content, cancellation, queued input, crossed clocks, delayed history and settled history |
| Image decoder native | PASS, 13 tests, Alcotest RLM1KUOP | Selection and artifact wire/content validation; native test output 0.004s |

Commands, source/fixture/binary hashes and exit codes are in each `*-result.json`; raw output is in its `.log`. Fixture HTTP servers and PTYs used isolated base paths. No production provider requests were needed.

## Visible frames

- `mixed-queue-80x40.png`: two server-queued requests plus one local NEXT remain `Queue (3 pending)`. The local row shows `NEXT 1`, without claiming accepted requests are running.
- `accepted-rechecking-120x40.png`: accepted request survives stream EOF and is marked for delivery rechecking; local NEXT remains.
- `reconnected-running-120x40.png`: RUN_STARTED removes the running input from pending while the local NEXT remains `Queue (1 pending)`. The terminal response was held during capture.

PNGs render the captured terminal text; they are not desktop screenshots. Colors/highlights are illustrative. `.txt` files retain the underlying text. Fixture history/memory endpoints are absent in the Queue scenario, so those unrelated error notices are visible and are not production errors.

`raw-pty-captures.tar.gz` contains every Queue/image `.ansi` and `.txt` capture. Image `*-open` captures precede dismissal and retain actual Kitty PNG transfer commands; text renderings alone do not prove how a particular graphical terminal displays that PNG. The fixture image is an 8×8 test PNG. Invalid artifact captures contain visible same-row label/reason and emit no image transfer before the next draft edit. Cancellation observes no image transfer for one second after fixture release, without claiming client mailbox completion.

## Findings addressed during verification

The earlier a35e12b9 build passed Queue behavior but its captured pending caption called two accepted requests “running turns”. Source review also found submission sequence was used backwards as dispatch order. #40384 removes that redundant inference and uses the existing waiting_for_keeper projection's position.

The initial image fixture expected a complete HTTP error that the 100-column footer clipped. The fixture now checks the visible reason and artifact label together in one completed frame, retains the no-image assertion and confirms the composer remains usable. Both final suites above ran against the same final TUI hash.

## Limits

This is macOS isolated fixture/native execution. Linux behavior, full application/recovery/transfer validation, release CI, installed-binary behavior and production success remain separate evidence obligations. The codec's earlier three-case native result is recorded in the sibling 2026-09-30-keeper-snapshot-codec folder; this TUI run does not expand that codec result.

Independent source reviews found no P0/P1/P2 at codec 0d1c21b82042ac18d204912dd759f7604cfd5269 and child cf6a0c37b52ce0a05ad4b717a4e98585c4cde131. A source verdict is distinct from these measured results and from formal GitHub approval.
