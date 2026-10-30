# Native Telegram integration evidence — 2026-10-25

Native Stack #45832 adds bot-owned poll custody (#45819), Keeper ingress and
terminal delivery (#45831), removes the external poller (#45834), and changes
the dashboard to native setup (#45836). These are source changes; the issue
#24497 remains open. The follow-up also consolidates the connector ID vocabulary used by navigation and setup.

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

A subsequent interface audit corrected the added fixture itself to use the
exported `canonical_json_string` API and parse its result, rather than refer to
a private error formatter. This strengthens the fixture to exercise the stored
JSON string boundary. Production/Owner fixture sources remain byte-identical to
run 40110391139's selected source (verified by an empty diff). A separate narrow
follow-up runs only the native gateway/custody/REST suites at source
`145ef89b52a1b5bf6296c4e4d1a805b2dedec045`; no running job was cancelled and the
Owner suite is not needlessly repeated for this fixture-only change.

## Observed repair execution: Keeper Owner passed, fixture build remains separate

Run [40110391139](https://github.com/jeong-sik/masc/actions/runs/40110391139)
subsequently **compiled and passed all 92 Keeper Owner cases**, including the
real Telegram poll → Gate → queued SQLite operation → strict source reload
scenario that had failed. The suite executed in 2.228s; see the retained
[excerpt](owner-persistence-followup.txt). This is actual acceptance/persistence
proof with injected Bot API HTTP, no model run, real Telegram or installed server.

The overall run still **FAILED** because its later native fixture referenced
the private formatter described above. Follow-up run
[40111004227](https://github.com/jeong-sik/masc/actions/runs/40111004227)
progressed past that repair but **FAILED** on the fixture's undeclared direct
configuration module. The native fixture now uses the repository's shared
`masc_test_deps` integration dependencies plus its explicit markup leaf, keeping
module ownership in the existing test SSOT. Production and Owner sources remain
unchanged. A new narrow request covers native gateway/custody/REST execution;
no native gateway suite PASS is attributed to these failed builds.

## Completed native follow-up

[Run 40111688477](https://github.com/jeong-sik/masc/actions/runs/40111688477)
at `08563e81e95089d5dd9739a9390341c9935327a8` completed **SUCCESS**:
8 native gateway cases, 10 poll custody cases, and 6 REST cases. See the
[execution excerpt](native-followup.txt). The production and OCaml test inputs
are unchanged at the subsequent dashboard/evidence head (empty diff over
`lib`, `bin`, `test`, `config`, Dune inputs and `scripts/ci`). These 24 cases
are separate from the 92 Owner cases recorded above. Full regression, browser
native-workflow suites, deployed gateway and actual Telegram/model reply remain
unverified. Earlier pending entries above record the sequence of observations.

The original issue also named duplicated connector ID literals. Navigation and
gateway setup now import one neutral `config/connector-ids.ts` vocabulary; the
route filter uses its typed membership predicate.

The existing navigation and connector-constants suites passed **31 tests** after
this consolidation. Command from dashboard:
`pnpm exec vitest run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 src/config/navigation.test.ts src/components/connector-constants.test.ts`.
See [the execution output](connector-ids-followup.txt). This is a separate run
from the earlier 140 cases; suite overlap is not counted as new unique coverage.

## Autonomous native wake follow-up (separate upper layer)

An original-scope gap remained after the native Owner operation path: generic
Ask/Fusion/owned-job wakes retained the continuation, but the autonomous
`keeper_surface_post` tool rejected Telegram/iMessage. There is no automatic
terminal publisher that compensates for that rejection.

The upper `fix/native-origin-wake-reply-20261025` layer adds a closed native
route behind the existing post tool and exact Gate approval/replay. Initial
admission reads only the selected connector's binding authority, and replay
reads its current binding again. Telegram retains bot/chat/topic/reply fields.
iMessage resolves the configured reply mode before approval and pins the actual
GUID; self-chat delivery is not evidence of delivery to the original group.
Actual delivery metadata distinguishes that destination from the origin binding
key. Uncertain transport failures do not authorize an automatic resend.

The new fixture restores an Ask_answered stimulus through the queue JSON wire,
uses the production wake projection and target/replay decoder, and exercises
the native sender with injected transport. It also covers refusal to change the
origin and authoritative binding ownership. This is not a complete model-driven
autonomous turn, actual Telegram/macOS send, or installed runtime test.
At this entry, OCaml parsing and tool TOML parsing passed; **the added OCaml
scenario has not executed**. Earlier 24/92 results do not certify this new layer.

The existing keeper-message and chat-primitives suites passed **211 tests**
including native receipt normalization. See [the output](wake-dashboard.txt).
This is fixture/DOM execution, without a new browser observation of this layer.
The earlier two unrelated baseline typecheck failures still apply.

### Autonomous follow-up compilation result

[Run 40113587452](https://github.com/jeong-sik/masc/actions/runs/40113587452)
at `939db8d04e8bbbd205b16cf9b2da3429db47d35b` completed **FAILURE**, before
any of its three selected suites executed. The runtime's native route lookup
had a fragile catch-all over the continuation variant (warning 4); an existing
Gate replay fixture omitted the added `To_native` constructor (warning 8).
The repair enumerates every continuation case and adds the missing test arm.
This source repair does not establish execution of the new wake scenario.
The same three suites are requested again; earlier lower-layer 24/92 results
remain separate. No local Dune build or CI watch loop was used.

### Native wake scenario observed; stale surface assertion repaired

[Run 40113998540](https://github.com/jeong-sik/masc/actions/runs/40113998540)
at `4926407ddf3d617c0ed65d11cb95ef6469ae40da` compiled the selected candidate
and **passed all 9 native gateway cases and all 35 Gate replay cases**. The new
Ask_answered queue-wire → production wake projection → exact target/replay →
injected native send case executed successfully, including actual iMessage
destination summary and strict receipt assertions. This remains injected
transport/source execution, not a full autonomous model turn or live connector.
See [the retained execution excerpt](wake-execution-followup.txt).

The aggregate run still FAILED: one of the 31 surface-post cases asserted the
old unsupported-surface error wording. Telegram without an origin was correctly
refused, but the fixture expected a particular substring. It now verifies
refusal of missing Telegram/iMessage origins and unknown surfaces through the
actual result, without constraining error text. Production source and the
native/Gate replay fixtures are unchanged; only the surface-post suite is
requested again. No 31-case PASS is claimed before that execution.
