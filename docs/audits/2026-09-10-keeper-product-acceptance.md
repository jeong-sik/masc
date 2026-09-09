# Keeper product acceptance — 2026-09-10

Scope: all 18 user-reported gaps after 0.35.2, plus the supplied product contract.
No row is complete. A prompt change is an intervention, not behavioral proof.

## Initial observations (historical snapshot)

- Source inspected: `e361d0f1c00a611c2c01f7aada77dd7e836dcb65`.
- Local `/health?full=1` on port 8935 reported the same binary commit,
  release/binary version `0.35.1`, and the requested base-path runtime root.
  This does not establish what ran in the user's earlier 0.35.2 observation.
- Keeper list returned 14 entries, without truncation: seven `failing`,
  three `offline`, four `running`. These are projections, not proof of process death.
- `analyst` status at 2026-09-09T16:07Z reports `failing`,
  `keepalive_running=false`, but `fiber_health=alive` and newer successful
  tool calls in turn 2852. Do not restart based on the summary alone.
- Its previous turn 2851 receipt reports `provider_attempt_effect_fenced`,
  diagnostic `Parse error: turn: unsupported stream message type "system"`.
  A historical payment error is also present in proactive metadata; it does
  not establish the cause of the current attempt.
- That receipt reports 111310 bytes of extra system context. This is one
  observation, not a token-waste measurement or fleet-wide distribution.
- `Keeper_unified_prompt.goal_summary` carries ID, title and phase; the
  displayed Active Goals rows do not themselves carry success criteria.
  Whether another context layer supplies them requires a full request audit.

## Subsequent evidence through 2026-09-09T18:43Z

- #34909 and #34919 merged: current Task/Goal success criteria are carried into
  Keeper and Librarian context. Deployment and behavioral effects remain separate.
- #34938 merged: live prompt override preserved and extended; API, persisted
  value and browser editor agree. A saved code-reviewer system prompt containing
  the exact section matches its turn-record block by SHA-256 and 9,128 bytes.
  This establishes measured input presence, not successful autonomous behavior.
- #34912 provides full preset inspection with CI-built browser evidence.
  #34927 has full ChatTranscript/actual worker evidence for original edit diffs;
  deployed autonomous-edit and LSP evidence is still missing.
- #34935/#34936 merged: local curator and streamed progress with completed 27B
  synthetic scenarios. The held-out streamed case took 564.34 seconds and kept
  both disagreement attribution and same-observer corrections. This is not a
  broad quality benchmark or an automatic semantic verification result.
- #34939/#34940/#34941 add live input, proposal publication/readback and server
  storage; delivery/CI work remains open. The installed server returned 404 for
  the context endpoint when tested, so no successful live ingestion is claimed.
- #34942 proposal UI: nine component/API tests and CI-built browser verification
  passed with saved model output and explicit synthetic error/selection fixtures.
  Exact evidence disclosure, retry, empty state and mobile overflow were checked.
  Its running-server integration and Keeper reuse are not yet demonstrated.

## Delivery update at 2026-09-09T19:32Z

- #34939, #34940 and #34941 are now merged. #34941's exact source
  `790323dccdb291fa13390acf1f1f43408efd7ac3` passed CI and its six
  proposal-storage scenarios in run 34393840993. #34940's publication CLI
  passed all twelve scenarios with its declared jsonschema dependency.
- The isolated CI-built runtime exposed 1,710 sources from 23 copied snapshots
  across 18 Keeper identities. Production remains a separate deployment; this
  does not establish that its context/proposal endpoints are available.
- The full single-request input measured 518,293 native tokenizer tokens against
  a loaded context of 262,144. The Keeper-group pass is now receiving its first
  group's stream; final synthesis, semantic assessment and publication remain
  open. See [aggregate evidence](../evidence/2026-09-10-workspace-memory-pass/README.md).
- #34943 Keeper retrieval is still open. The TUI exhaustive-match failure was
  repaired and the rebased source is undergoing CI. Overview statistics are
  implemented in a separate worktree; review found a pending-cache loading issue
  that is being repaired before browser verification.

## Verified update at 2026-09-09T22:27Z

- #34960, #34963, #34967, #34972 and #34974 are merged. The isolated
  17b9 candidate includes Edit result persistence, image configuration and image
  adoption. It does not include the later thinking-presence or Gate continuation
  work, and it is not the production deployment.
- The actual Keeper selected the configured creative image while its old
  container remained running. ReportLab, CairoSVG, Nanum and Poppler were
  independently observed. PyMuPDF and pypdf are absent; an inaccurate operator
  instruction was corrected. The PDF remains the rejected 15,691-byte file
  with SHA256 `3b7534e691b1a8cb53b9049a9d931e5a5c8fa37466f62d836aea492d26829e0e`.
  See [image adoption](../evidence/2026-09-10-image-adoption/README.md).
- The real Keeper Edit returned success and a durable manifest with both
  historical snapshots; all three hashes/lengths were checked. Evidence is
  submitted in #34977. This is not yet the corresponding live chat diff or LSP proof.
- #34972 has CI-built browser evidence for the actual IDE heartbeat panel with
  synthetic inputs, including four states and a 390px viewport. It removes
  unsupported saved/conflict claims; it does not establish memo persistence or
  full IDE behavior. See [browser evidence](../evidence/2026-09-10-ide-heartbeat/README.md).
- Goal creation already requires nonblank metric and target fields. Actual
  isolated MCP accepted a declared criterion, rejected a missing target, and
  returned only the accepted Goal with its original criterion revision.
  Completion proof is wired; creation feasibility and human final confirmation
  remain separate. #34976 is open and has failed compilation/type checks under
  repair; no completed human-confirmation runtime is claimed.
- Fusion already persists deliberation results to Board/chat and exposes runs.
  Missing behavior is work attribution and the Keeper's adopted/rejected choice
  with reasons, rather than absence of result storage. A separate implementation
  is in progress; no autonomous decision-use proof exists yet.
- The local whole-corpus process was still live when polled. Its first group
  reported 72,047 chunks, 215,838 thinking characters and zero content characters
  at 22:23:47Z. There is no completed whole-corpus synthesis to accept. The live
  process was not restarted because of elapsed time or slow output.

## Measured continuation at 2026-09-09T23:05Z

- The same whole-corpus process handle remained live. Its first Keeper group
  finished at 22:33:59Z with 75,340 chunks, 4,562 content characters and
  219,399 thinking characters. The 4,563-byte result has SHA-256
  `09438670ab80d991bab0cc8a9b80efc869a45401c875d312767dba13e01a6b83`;
  its parsed structure contains two shared claims, one excluded source and no
  conflicts. These are structural observations, not semantic acceptance.
  The second group was receiving at 23:05:33Z; one of eighteen groups had
  completed. No whole-workspace synthesis or publication is claimed.
- The isolated PDF Keeper's previous operation was independently read as
  `Succeeded`, but its script still used `re.search` without importing `re`.
  Script SHA-256 was
  `b13c313f35c6d92ca0a4505defdcb22f23e8988f6b96767d919b816d8b639feb`.
  A correction request was admitted as
  `kmsg-e4bbdde95378d90cc8d90f8e459d32e3`; admission is not a repaired PDF.
- #34980 contains twelve completed operator-initiated Kimi turns and actual
  final recall of the initial home and time after ten intervening turns.
  This short, single-runtime observation does not prove autonomous behavior,
  failover, compaction or hour-scale continuity. Its recorder was subsequently
  corrected to reject evidence directories bound to a different scenario.

## Acceptance matrix

| # | Requirement | Evidence needed to close | Current state / next work |
|---|---|---|---|
| 1 | Goal/Task focus | Autonomous action receipts linked to assigned goal and remaining acceptance criteria across turns | Prompt section found in measured agent input (#34938); autonomous scenario still needed |
| 2 | Important decisions use Fusion and are recorded | Real decision request, durable run, result, adopted/rejected reasons linked to work | Durable deliberation runs exist; originating work and Keeper decision-use attribution are missing; implementation and behavior proof pending |
| 3 | Goals guide work without deadlock/repetition | Success criteria in context; blocked dependency with independent progress; rejection recovery and human-confirmed completion | Criteria context and actual creation/readback proven; human final confirmation implementation #34976 is under CI repair; live recovery/continuity pending |
| 4 | Keepers do non-code work | Research and creative tasks completed with independent verification | No current scenario proof |
| 5 | Multiple expressive file formats | Useful original artifacts, correct MIME/format, open/render/play proof for requested document/image/audio/video formats | Creative image tools and actual Keeper image adoption proven (#34974); PDF remains rejected; useful document/image/audio/video outputs still required |
| 6 | Initiative | Role-appropriate autonomous work initiated and advanced without repeated user nudges | Prompt intervention; live sequence pending |
| 7 | Requests to owner/operator | Specific actionable ask, answer, resumed dependent work, independent progress while waiting | Prompt intervention; live ask lifecycle pending |
| 8 | Keeper delegation | Scoped assignment, recipient action, evidence returned and integrated, no duplicate ownership | Prompt intervention; two-Keeper scenario pending |
| 9 | Standalone agent context/flexibility | Exact verifier/judge/librarian requests contain purpose, inputs, evidence and recovery context; successful revised judgment | Librarian goal criteria merged (#34919); local curator requests/results captured; verifier/judge context and live recovery pending |
| 10 | Token clarity/efficiency | Per-turn context composition and usage provenance measured; duplicate content removed with continuity preserved | One 111310-byte receipt observed; causal profiling pending |
| 11 | TUI/Dashboard statistics | Rendered token, latency, outcome, goal progress and collaboration data matched to receipts | Source has metrics; screenshots and denominator checks pending |
| 12 | Tools/Skills discoverability | User finds capability, full description/schema/instructions and availability with clear navigation | Browser/TUI interaction proof pending |
| 13 | Configuration feedback | Edit/save/reload shows effective source/value and verifies next request changed; errors visible | Keeper override save/readback/editor and measured input join proven (#34938); other settings and behavioral feedback pending |
| 14 | Preset prompt inspection | Full preset content preview and effective selected prompt visible before/after application | Full preset/effective preview and CI-built browser proof in #34912; deployed current screen verification pending |
| 15 | Chat diffs and LSP | Real autonomous edit yields linked diff; actual LSP availability and diagnostics accurately shown | #34924 stores patch originals; #34927 verifies and displays their diff. Component and CI-built browser scenarios pass (synthetic HTTP records, actual worker); full ChatTranscript scenarios also passed; deployed autonomous edit, remote edit coverage and LSP diagnostics remain pending |
| 16 | Workspace, comments, memo/history | Repository-scoped accumulated work, notes and comments survive switch/reload and link to changes | Unsupported saved/conflict labels removed with actual-component browser proof (#34972); repository-scoped history/comments/memo persistence still pending |
| 17 | Shared memory agent/lane | Cross-Keeper evidence consolidated with attribution/deduplication and retrieved in subsequent work | Local standalone curator exists; proposal store/readback/UI in #34940/#34941/#34942; actual Keeper retrieval and live consolidation pending |
| 18 | Local LLM roles | Configured local verifier/judge/librarian role produces useful checked results with measured runtime identity | Local 8B failures and 27B useful synthetic results measured; broad quality, live role integration and provider/runtime comparisons pending |

## Delivery sequence and proof requirements

1. Establish trustworthy current execution observations and capture model context;
   reconcile status/receipt/live-fiber disagreement without interrupting live work.
2. Carry success criteria, actionable work and relevant evidence through context;
   exercise purposeful work, Fusion, delegation and operator requests.
3. Produce non-code artifacts and shared memory; exercise standalone/local roles.
4. Expose those same records in TUI/Dashboard, including configuration and IDE flows.

At each boundary use CI, then keep working on an independent slice instead of
watching CI. Review implementation and compare deployed bytes before claiming
runtime behavior. Capture logs and browser screenshots. Run continuity scenarios
for 10+ turns and 1h/2h/4h/24h across available runtimes, including failover and
memory of earlier actions. A short twelve-turn single-runtime recall observation
is recorded in #34980; hour-scale and cross-runtime checks remain unproven.

Reference: [Anthropic, Building effective agents](https://www.anthropic.com/engineering/building-effective-agents)
describes dynamically scoped delegation and result synthesis. The intervention
uses explicit purpose/input/output/evidence for collaboration; no numerical
activity quota or control-flow budget is introduced.
