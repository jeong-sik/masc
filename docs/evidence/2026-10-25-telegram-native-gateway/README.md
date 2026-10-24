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
path is normalized to `<worktree>`. This test result is DOM/fixture behavior. The separate browser observation below
checks candidate UI rendering, not the native backend or an installed bundle.

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
external poller. No installed candidate binary, external poller shutdown, live Telegram request,
model reply or deployed candidate UI was produced. The parent PR's
custody-only CI evidence is separate from this actual Keeper integration scope.

## Candidate UI observation

Source `7eb9a49bb764221d04dfda739d35465c503f6d8f` was served by a temporary Vite
listener on loopback port 5517. Ego Browser rendered the actual Telegram route
and opened Config; [the cropped screenshot](telegram-config-candidate.png)
shows the native token/permission guide and a token placeholder, not a secret.
The capture was visually inspected. No binding, configuration write, Keeper
request or outbound message was submitted. The agent's browser task and Vite
listener were closed after capture.

The candidate frontend proxied the existing server on port 8935. Its full health
reported version 0.64.0, effective base `/Users/dancer/me`, effective MASC root
`/Users/dancer/me/.masc`, and no top-level git SHA. That runtime was not replaced
or matched to this candidate. Its Telegram API still reported a missing status
file; this is explicit mixed-version observation, not native poller deployment
proof. Other runtime activity is outside this UI inspection.

Browser procedure: ego-browser skill, one task space (26), navigate to
`/dashboard/#connectors?section=connector-status&connector=telegram`, inspect
semantic snapshot, open Config, wait for the native config panel, capture that
panel's actual DOM rectangle and visually inspect it. No page mocks were used.

## Follow-up: persisted coordinate ordering failure and repair

Run **40108964093 failed**. The Keeper Owner executable compiled and ran 92
cases; the new Telegram case was its sole failure (the suite ran in 2.266s after
compilation). The real poll/acceptor path had queued an operation, but its stored
source could not be decoded: `Telegram Keeper operation surface differs from
its exact route`. This invalidated the earlier integration SOURCE PASS, and an
append-only FAIL correction was posted to #45831.

The operation store recursively canonicalizes JSON object keys. A generic Gate
surface's address is represented in OCaml as an association list; structural
list equality had mistaken changed key order for a changed destination. Repair
`0f228cdaf5a407e5326b87aabd26d659c5b20b71` gives the producer canonical address
order and uses exact sorted-map equality at both strict source validation and
terminal stored-row selection. Duplicate, missing, unknown and changed
coordinates remain refusals. The native fixture now exercises the actual
canonical JSON transformation and full-map adversarial cases. Its missing direct
Ids dependency was also declared; the previous native-test batch had stopped at
that compile error, so no passing result is attributed to it.

The repaired native source received independent source review; this does not
prove that the repaired Owner scenario has executed successfully. A new focused
request at upper source `9a9109d9c5c34dbfbe457f2e0a0e8ebfb092051c` selects only
`test_telegram_native_gateway,test_keeper_owner,test_telegram_poll_custody,test_telegram_rest_client`.
The result remains pending at this update. Frontend source is unchanged from the
140-test and candidate screenshot observations above.
