# 1Password Add-on docking

Tracking: [#45736](https://github.com/jeong-sik/masc/issues/45736).

The requested outcome is an installed connector a Keeper can use to sign in
through its existing browser, with user approval in 1Password, then continue its
original task. Passwords and OTPs must never reach model arguments, tool results,
retained observations or logs. A status-only tool does not satisfy that outcome.

## Implemented foundation

- `addons/onepassword/oauth.py`: code + S256 PKCE, backend-only token/key storage,
  configuration identity, connection generation, serialized rotating refresh,
  expiration-aware revoke and explicit uncertain-operation recovery states.
- `addons/onepassword/lane.toml`: normal native MCP package, seven host-context
  tool exports, packaged skill and declared connection readings. It does not declare
  another Browser service.
- `onepassword_status`: safe account projection. `browser_login_available`
  describes configured admission and does not certify a website login.
- Private operator connection source: discovered `lane_operator`, admin-only
  host ingress, original-incarnation/connection authority, the generic Dashboard
  connection panel, callback fragment capture and transaction-pinned cancel.
  See [operator control contract](lane-addon-operator-controls.md).
- Browser private-session source: original backend/session pin, existing page
  serializer, public-extension settlement checks and unknown/cancel fences.
  CDP/private Unix errors discard raw payload/exception text at their first
  boundary. The [companion session contract](browser-private-companion-session.md)
  records the private Browser owner/wire port and original-CDP extension loader.
  Exact CDP target to numeric Chrome tab mapping uses the existing Stagehand
  extension's debugger table. Companion loss cancels and joins active public or
  private work; results returned during cancellation cannot escape the fence.
- Package-owned `prepare.js`/`autofill.js`: real extension initialization,
  whole-browser agentic mode, request/status and credential fill with exact tab
  checks, entry-ID grant selection and private error projections. Eight Node
  fixtures execute these actual programs with a fake extension API and passed.
  The original private host broker and Python client invoke that source path.
- A separate Service-owned Publisher drains immutable journal envelopes through
  the version-3 private broker. The host retains canonical notices, durably
  admits the original Keeper source and rereads it at intake. Grouping preserves
  the original invocation, Task and conversation. These are source boundaries;
  their presence does not prove website authentication or resumed task work.
- The focused Python suite passed 131 checks at source
  `969148a6a7d1ebbda3355ae99c89f4eddf5c023e`, including actual Service, journal,
  socket and MCP subprocess scenarios with fabricated credential/Browser edges.

## Observed native candidate

On 2026-10-25, [run 40147809672](https://github.com/jeong-sik/masc/actions/runs/40147809672)
built source `6e6491e9cec86347b6664d26821cba95eda080f7`. Five original-source
and five publication fixtures passed, along with the allocation and protocol
suites. The extension and broker fixtures still had two failures repaired by
the later candidate. Build success did not make that run successful.

[Run 40149926239](https://github.com/jeong-sik/masc/actions/runs/40149926239)
subsequently built source `60303e6d5c3334df8a4827448e2a2fc6b84c5071` and
passed all seven selected suites, 108 tests. A later artifact-copy step failed
when overwriting an already retained read-only executable, so the real Chromium
probe was skipped and the overall run failed. These results do not cover the
new invocation-acceptance and detected-owner-loss changes above that source.

The retained server and 1Password package from source
`6e6491e9cec86347b6664d26821cba95eda080f7` were run in a separate temporary
workspace. The executable's embedded commit and effective
runtime roots were checked. The declaration API attached its native worker,
and an initialized MCP client discovered all seven exports. An actual Keeper
model turn invoked `onepassword_status` once and returned `not_configured`,
`connected = false`, `browser_login_available = false`.

The retained tool execution and completed operation both identify
`trace-1792891063051-00000#1`. Private receipts preserve that join. The smoke
observer initially expected lowercase terminal states and timed out despite the
operation's recorded `Succeeded`; a separate retained-execution check established
the status-call result. This was an isolated candidate, not a production upgrade,
real account connection, Browser fill or original-task continuation.

The same native source also exercised the actual 1Password package with
fabricated local account state and a nonexistent Browser selection. Its first
Keeper turn received `preparing`; the real worker Publisher delivered the later
`outcome_unknown` through the host broker and durable queue. The queue's actual
terminal receipt and the second model input preserved the original invocation.
With explicit instructions to use `keeper_surface_post`, that second real turn
posted the same operation ID and phase to the original Dashboard conversation;
the assistant row was persisted. The original Task was null, and no actual
1Password account, extension fill or website authentication was exercised.
The [continuation contract](lane-addon-keeper-continuation.md#observed-isolated-failure-continuation)
records the evidence scope.

A further isolated run of that same source established a non-null Task path.
An actual Keeper claimed and auto-started `task-001`, invoked `onepassword_login`
in `trace-1792893853333-00000#2`, then received the canonical failure in `#3`.
The original record, queue receipt, both tool contexts and resumed turn retained
`task-001`. Its actual `keeper_surface_post` persisted message
`msg-1792893883329673-7` in the original Dashboard conversation, and the Task
remained in progress. This is controlled failure continuation; it does not
establish successful sign-in or work on an authenticated website.

## Earlier status installation

On 2026-10-24, candidate `dc3e8ed35ff065c4cff859a8473531b4561373db`
was copied as an explicit development package and installed through the served
workspace's declaration API. The running MASC binary identified itself as
`8eac5c07c290d134a9ef6acb1e298584bf9a1366`; it was not rebuilt from this stack.
Desired and applied declaration revisions matched, the native worker attached,
and its declared connection row was retained. An external coding agent initialized
an MCP session, discovered `onepassword_status`, then invoked it through the
server's normal exported-tool path. The result was:

```json
{"phase":"not_configured","connected":false,"browser_login_available":false}
```

The running Dashboard displayed the attached development installation. Its
existing bundle/server mismatch banner remained visible; no Dashboard upgrade or
broader runtime-health claim is made. Local receipts and screenshot are under
`reports/onepassword-addon-20261024/` in the development worktree. They are not
published account-authentication evidence.

## Remaining work

1. Exercise the implemented private connect/callback/cancel and login approval
   controls on a host built from this stack. Extend them with confirmed disconnect and
   explicit remote reconciliation for an interrupted exchange or rotation.
2. Install and exercise the supported extension through the implemented loader
   on the existing owned Chromium backend and verify its connected private transport
   through the Python connector. The companion uses the original Browser owner, CDP
   connection and page-operation serializer.
3. Verify actual request/status/fill and the implemented account, Browser,
   session/tab and principal pins. Exercise the read/screenshot exclusion and
   original-owner cancellation fences while a real extension call is in flight.
   A lost fill cannot authorize replay or adoption of another Browser.
4. Exercise the implemented host-owned unknown notice after detected original
   provider loss. It requires confirmed invocation acceptance; an origin record
   alone remains pre-dispatch intent and cannot prove execution. Whole-host crash
   recovery is outside that source implementation's guarantee.
5. Verify worker publication, durable intake and the original Keeper's resumed
   turn through the connected path. Generic Lane Ask stores question text and
   does not itself resume a Keeper; it must not carry opaque approval links.
6. Verify install, model-visible discovery and actual Keeper invocation, real
   user approval, website-level authenticated readback and resumed task work.
   Exercise denial, stale owner, concurrent observation, cancellation, unknown
   result, multi-page login/OTP and disconnect using the same candidate.

Provider setup requires developer integration access, OAuth client registration
and a production HTTPS callback. The [personal offering](https://1password.com/personal-ai-agent-integrations)
includes Individual/Family accounts; the [documented developer registration](https://docs.browserbase.com/integrations/1password/agentic-autofill)
uses a separate Business account. Missing OAuth Application access requires
activation by a 1Password contact. The required test account and extension/app build
must be confirmed with 1Password. No personal account is connected by the
development status installation above.

References: [1Password partner guide](https://www.1password.dev/agentic-autofill/partners),
[extension API](https://www.1password.dev/agentic-autofill/partners/extension-api),
[Browserbase implementation](https://docs.browserbase.com/integrations/1password/agentic-autofill).
