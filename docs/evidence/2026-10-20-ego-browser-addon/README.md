# Optional ego companion: direct execution evidence

2026-10-20 KST. This evidence covers the package host adapter and its isolated
observation worker, not a production MASC installation or general Keeper access.
The native application was ego lite 0.6.0.16 with SDK guide v2.1.0, already
installed/onboarded on this macOS host. No existing login tab was operated.

## Native host adapter

The exact JSON requests in `native-requests.json` were sent on stdin to
`addons/ego-browser/skills/ego-native/scripts/host.py --state-dir <private-dir>`.
Every request invoked the fixed native program and returned the next snapshot.
Input selectors were supplied by the fixture; these are scripted feature checks,
not a blind benchmark of element discovery, LLM decision turns or token use.

`native-results.json` retains the complete native result and independently
captured HTTP fixture events for each request:

| Scenario | Native result | Authoritative fixture events |
| --- | --- | --- |
| Hover Reports, wait, click Export | postcondition_met | trusted hover → click → completed |
| Click Archive below the fold | postcondition_met | wheel scrolling → trusted click → completed |
| Drag Task Alpha into visible Done | postcondition_met | trusted pointerdown → pointerup inside Done → completed |
| Drag to Done outside the viewport | outcome_unknown | scrolling but no trusted drag/completed; final snapshot says Not completed |

The last case is deliberately negative: ego's drag returned without throwing,
but the adapter's explicit final-state wait failed. It did not report task
success. The returned partial progress remains evidence that API calls returned,
not that the placement happened. This fixture tests pointercapture gestures;
it is not HTML5 DataTransfer or OS file dragging.

Each exact request was submitted again. All retained results were identical and
the fixture event arrays remained unchanged (`duplicate_equal` and
`events_after_duplicate_equal`), including the uncertain drag. No native input
was replayed under the same request identity.

`hover.png` and `drag.png` are captured native page screenshots. Their digests
match the corresponding result's screenshot hash; the native absolute paths in
the receipts describe the capture location, not a portable link to that file.
The images in this directory retain those bytes. The scripts, PNGs
and package manifest were hashed; `source-hashes.json` binds the package scripts
and manifest used by this run.

## First-open recovery

After native space 3 was created, the private test state was fault-injected to
simulate a crash before saving the first-open binding/receipt. The dispatch
record and pre-saved owner intent were retained (`recovery-fault-injection.json`).
An explicit `recover` used that installation-owned native name and returned the
same space 3 and epoch, without creating or claiming another space.
`native-recover-result.json` preserves the binding/result; initial new-tab page
contents are explicitly omitted from its snapshot field. This is simulated
post-creation persistence loss, not proof that the operating system actually
crashed. The subprocess tests separately exercise an absent structured reply.

## Isolated observer image

The package image was built from its Dockerfile. `container-worker-proof.json`
records the actual image ID and `docker run` command with network disabled,
read-only filesystem, CPU/memory/PID envelope, dropped capabilities and
no-new-privileges. MCP initialize, tools/list and lane_observe succeeded under
Python 3.12 in that container. Supplying the actual native negative-case capture
retained `outcome_unknown`, incomplete coverage and the original request/space
identity. That is worker protocol/image evidence, not MASC reconciliation or UI
installation evidence.

## Source checks and limits

`python3 -m unittest discover -s addons/tests -p 'test_ego*.py' -v` passed 16 tests
covering process-boundary request validation, lost replies, duplicate identity,
concurrent callers, owner naming, recovery intent, strict replies and source
provenance. Those tests use a fake native executable and do not replace the
real input evidence above. TOML parsing and `git diff --check` also passed.

No OCaml build or full CI was run. No MASC server config/backend or Keeper
native-tool/approval policy was changed. Full MASC configuration reconciliation,
Dashboard display and official Keeper native Bash execution remain unverified.
The observation lane does not export host actions as generic Keeper tools.

After verification, a fresh observation confirmed the negative drag's final
state; `finish` closed the owned task Space (`cleanup.json`). The owned HTTP
fixture process was then stopped.
