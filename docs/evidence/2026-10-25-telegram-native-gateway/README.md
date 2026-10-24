# Native Telegram integration evidence — 2026-10-25

Native Stack #45832 adds bot-owned poll custody (#45819), Keeper ingress and
terminal delivery (#45831), removes the external poller (#45834), and changes
the dashboard to native setup (#45836). These are source changes; the issue
#24497 remains open. The final evidence commit changes documentation only.

## Measured dashboard behavior

Source: `f01373f25ffa2c10a5da4ffd3dbc5072b01ceee5`. The six existing focused suites passed **140 tests**:
`connector-status`, `connector-overview-strip`, `connector-readiness-rail`,
`connector-paths-strip`, `connector-constants`, `connector-setup-guides`.
See [the actual result log](dashboard-focused.txt); only the local working
path is normalized to `<worktree>`. This is DOM/fixture behavior, not a browser,
installed bundle, screenshot or live server measurement.

Command, from dashboard:

```sh
pnpm exec vitest run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 src/components/connector-status.test.ts src/components/connector-overview-strip.test.ts src/components/connector-readiness-rail.test.ts src/components/connector-paths-strip.test.ts src/components/connector-constants.test.ts src/components/connector-setup-guides.test.ts
```

`pnpm exec tsc --noEmit` is **not passing**: two errors remain in unchanged
`src/keeper-stream.test.ts`. An archive of baseline
`b33506e601f5ee9ea843369a9fc6039c39a0820c`, including dashboard and test fixtures,
with the same frozen dependencies reproduced [identical output](dashboard-typecheck.txt).
This isolates the existing failures; it does not convert them into a typecheck PASS.
Connector CSS was parsed with PostCSS while removing the deleted widget selectors.

## OCaml verification and source review

No local Dune build ran. Changed OCaml source/interfaces passed parsing.
[Run 40107802197](https://github.com/jeong-sik/masc/actions/runs/40107802197)
at `8a1376b2724a973aaea72047f1f6ddd2d31947cc` failed compilation before the new
Owner/native integration fixtures ran: new Telegram code had fragile error
matches, a missing qualified Role namespace and a direct Gate test dependency;
existing browser native-workflow consumers also lacked exhaustive cases.
Those errors were repaired in source, without adding fallback wildcard branches.

[Run 40108964093](https://github.com/jeong-sik/masc/actions/runs/40108964093)
was explicitly requested at `b6444d8550231840c77aae606315bcae26fafab1` for
`test_telegram_native_gateway,test_keeper_owner,test_telegram_poll_custody,test_telegram_rest_client,test_browser_selection,test_browser_native_workflow`.
Its result is pending at artifact creation. The later dashboard P2 fixes do not
change its OCaml source/test inputs. No CI watch/wait loop was used.

Independent source review caught and corrected two P1s: binding-path override
loss and silent structured reply loss. Native source was re-reviewed at
`b63a56d401cfeff5a40ca050d65e80b7a0e7b762`. Dashboard review caught and corrected
configuration-versus-connectivity and credential-source guidance errors.
Review artifacts are source verdicts; draft PRs have no guarded approval footer
or formal independent GitHub approval from these sessions.

## Behavior and remaining limits

The original Telegram coordinates and durable operation identity are retained.
Terminal output loads a unique committed assistant row by exact turn and
matching surface/conversation; provider deltas and abandoned attempt media do
not authorize output. Public blocks render as independently balanced HTML;
reasoning/trace blocks are excluded. The sender verifies the configured bot and
keeps actual message IDs when a later chunk fails. Transport uncertainty stays
failure rather than triggering a blind resend. Protocol authority:
[Telegram Bot API](https://core.telegram.org/bots/api#sendmessage).

Private media references/binary upload and automatic partial-send resume remain
open acceptance. Removing source/services APIs does not stop an already-running
external poller. No installed binary, service shutdown, live Telegram request,
model reply, deployed UI or physical screenshot was produced. The parent PR's
custody-only CI evidence is separate from this actual Keeper integration scope.
