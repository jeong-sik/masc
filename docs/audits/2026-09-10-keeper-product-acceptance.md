# Keeper product acceptance — 2026-09-10

Scope: all 18 user-reported gaps after 0.35.2, plus the supplied product contract.
No row is complete. A prompt change is an intervention, not behavioral proof.

## Current observations

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

## Acceptance matrix

| # | Requirement | Evidence needed to close | Current state / next work |
|---|---|---|---|
| 1 | Goal/Task focus | Autonomous action receipts linked to assigned goal and remaining acceptance criteria across turns | Prompt intervention; inspect full model request and goal detail access |
| 2 | Important decisions use Fusion and are recorded | Real decision request, durable run, result, adopted/rejected reasons linked to work | Handler and result fragments exist; behavior unverified |
| 3 | Goals guide work without deadlock/repetition | Success criteria in context; blocked dependency with independent progress; rejection recovery and human-confirmed completion | Summary is ID/title/phase; scenario execution pending |
| 4 | Keepers do non-code work | Research and creative tasks completed with independent verification | No current scenario proof |
| 5 | Multiple expressive file formats | Useful original artifacts, correct MIME/format, open/render/play proof for requested document/image/audio/video formats | Prompt intervention; tool availability and real outputs pending |
| 6 | Initiative | Role-appropriate autonomous work initiated and advanced without repeated user nudges | Prompt intervention; live sequence pending |
| 7 | Requests to owner/operator | Specific actionable ask, answer, resumed dependent work, independent progress while waiting | Prompt intervention; live ask lifecycle pending |
| 8 | Keeper delegation | Scoped assignment, recipient action, evidence returned and integrated, no duplicate ownership | Prompt intervention; two-Keeper scenario pending |
| 9 | Standalone agent context/flexibility | Exact verifier/judge/librarian requests contain purpose, inputs, evidence and recovery context; successful revised judgment | Request capture and role audit pending |
| 10 | Token clarity/efficiency | Per-turn context composition and usage provenance measured; duplicate content removed with continuity preserved | One 111310-byte receipt observed; causal profiling pending |
| 11 | TUI/Dashboard statistics | Rendered token, latency, outcome, goal progress and collaboration data matched to receipts | Source has metrics; screenshots and denominator checks pending |
| 12 | Tools/Skills discoverability | User finds capability, full description/schema/instructions and availability with clear navigation | Browser/TUI interaction proof pending |
| 13 | Configuration feedback | Edit/save/reload shows effective source/value and verifies next request changed; errors visible | Runtime config source exists; end-to-end proof pending |
| 14 | Preset prompt inspection | Full preset content preview and effective selected prompt visible before/after application | UI/source audit pending |
| 15 | Chat diffs and LSP | Real autonomous edit yields linked diff; actual LSP availability and diagnostics accurately shown | #34924 stores patch originals; #34927 verifies and displays their diff. Component scenarios pass; CI-built browser, deployed autonomous edit, remote edit coverage and LSP diagnostics remain pending |
| 16 | Workspace, comments, memo/history | Repository-scoped accumulated work, notes and comments survive switch/reload and link to changes | Source and rendered audit pending |
| 17 | Shared memory agent/lane | Cross-Keeper evidence consolidated with attribution/deduplication and retrieved in subsequent work | Role, storage ownership and live scenario pending |
| 18 | Local LLM roles | Configured local verifier/judge/librarian role produces useful checked results with measured runtime identity | Local capability discovery and comparative trial pending |

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
memory of earlier actions. None of those longitudinal checks has run in this pass.

Reference: [Anthropic, Building effective agents](https://www.anthropic.com/engineering/building-effective-agents)
describes dynamically scoped delegation and result synthesis. The intervention
uses explicit purpose/input/output/evidence for collaboration; no numerical
activity quota or control-flow budget is introduced.
