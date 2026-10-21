# Existing lanes as Addons: ownership and extraction boundaries

This is the source-backed extraction plan for worklist B01 and D02. It records
what can move and which host decisions must stay authoritative. It does not claim
that the listed lanes have been extracted or that a new worker has executed.

Source inspected on 2026-10-21:

- Main `b95d927e30c6718e0fe656d3019c6cf39766c02c` for current domain owners and callers.
- Observation stack #44710 through `7f9e34bab08484124bb18a477ecb5e5ba0fb5769`
  for retained-worker UI behavior.
- Browser stack #44168 through `76b741f8816f074249baef3166ca152d9c9d2c13`
  for the consumer request-schema grant. That grant is an unmerged dependency,
  not an API available in the inspected main revision.

## Common ownership

The host owns workspace admission, caller identity, credentials, provider
admission, durable source snapshots, accepted request identity, domain commits,
artifact access, and final settlement. A worker owns the execution resources
assigned to its exact installation and incarnation. An observation is a read
model; neither a visible graph nor a retained worker grants execution permission.

Reuse the ports already declared in
[`Lane_addon_runtime`](../../lib/lane_addon/lane_addon_runtime.mli):

- `register_exact_runner` and [`Server_lane_addon_exact.runner`](../../lib/server/server_lane_addon_exact.mli)
  for declared exact outputs; `register_sampling_factory` for permitted sampling.
- `dispatch`, `scheduled_act`, and the retained
  [`Lane_addon_action.receipt`](../../lib/lane_addon/lane_addon_action.mli)
  for worker actions and their original outcomes.
- `tool_export_snapshot`, `call_exported_tool_with_authority`, and
  `register_skill_export_handler` for current tool and Skill discovery.
- `reconcile_configuration`, `read_declaration`, and `save_declaration` for
  installation configuration. Do not add a parallel registry for each domain.

These ports provide infrastructure, not a ready-made durable domain consumer.
Each extraction must connect its host-owned pending work to an actual worker
request and validate the returned decision before the existing domain commit.

## Model lanes

| Lane | Existing input and judgment seam | Host-owned effects and storage | Extractable work and lifetime |
| --- | --- | --- | --- |
| Candle Appraiser | [`Candle_appraisal.runner`](../../lib/candle/candle_appraisal.mli) takes an identity and Grade/Relation/Weights request; [`Server_candle_appraiser.run`](../../lib/server/server_candle_appraiser.ml) renders prompts, executes declared slots, fully decodes the answer, and records a run. | [`Candle_appraise.settle_one`](../../lib/candle_runtime/candle_appraise.ml) rechecks candidates, current policy, settlement identity and ledger cursor; the ledger determines money. [`Candle_payout_worker`](../../lib/candle_runtime/candle_payout_worker.mli) owns per-Goal scheduling and pending obligations. | Move the actual judgment worker and its request/result lifecycle. Keep the existing injected runner as the domain entrypoint. Bootstrap currently passes `Server_candle_appraiser.run` to `Candle_payout_worker.start` in [`server_runtime_bootstrap.ml`](../../lib/server/server_runtime_bootstrap.ml). Off refuses new judgments and retains obligations. |
| Workspace Curator | [`Server_workspace_memory_curator`](../../lib/server/server_workspace_memory_curator.mli) has separate reflect and briefing execution callbacks; [`start_with`/`run`](../../lib/server/server_workspace_memory_curator.ml) own the current lifecycle. | Workspace fact intake, pending batches, ledger revision/commit, briefing source and replacement fences remain host-owned. A retained input is not consumed by a missing or invalid answer. | Extract reflect/summary execution together with accepted request ownership. Preserve the existing rule: Off refuses new work, already accepted work can finish. Keep `request` as a host wake rather than creating another poll loop. |
| Librarian | [`Keeper_librarian_runtime.infer_memory_step` and `infer_working_state`](../../lib/keeper/keeper_librarian_runtime.mli) expose the inference boundary. [`Keeper_librarian`](../../lib/keeper/keeper_librarian.mli) owns the pure input/proposal codec. | Memory selection application, absorption gates, lineage, continuity, official/unread ranges and progress stay with [`Keeper_librarian_durable_consumer`](../../lib/keeper/keeper_librarian_durable_consumer.mli), Memory OS and [`Keeper_librarian_progress`](../../lib/keeper/keeper_librarian_progress.mli). `commit_with_runtime` is an existing effectful caller; `run_best_effort` is not an inference-only function. | Consider extracting inference only. Do not move the complete `run_best_effort` adapter into a worker: it also commits Memory/continuity. Purge must still stop and observe the running owner before moving progress. Extraction scope needs a separate implementation decision and continuity evidence. |
| HITL Auto Judge | [`Hitl_summary_request.capture_context_bundle`/`parse_summary`](../../lib/keeper/hitl_summary_request.mli) freeze host facts and decode judgment. [`Hitl_summary_worker.spawn`](../../lib/keeper/hitl_summary_worker.mli) admits a whole ordered exact flow before forking. | Approval queue, source identity, durable bind/release/terminalization and external-effect authority remain host-owned. `on_summary` follows verified provenance and durable completion; a summary is not permission to run an effect. | Candidate boundary is judgment execution. Preserve AGENT_CORE ownership of admission/attempts/failover and the worker's terminalization rules. Required availability must survive replacement; an arbitrary Optional-style Off is insufficient. |
| Board Attention | [`Keeper_board_attention_exact_flow.prepare`/`execute`](../../lib/keeper/keeper_board_attention_exact_flow.mli) snapshot one resumable durable candidate and execute an affine flow. | [`Keeper_board_attention_worker`](../../lib/keeper/keeper_board_attention_worker.mli), candidate/partition stores and owner intake retain Ready/claim/Blocked/recovery, completed-result delivery and consumption. A delivery failure must not consume its candidate. | Extract execution only after retaining before-dispatch and before-advance provenance callbacks. Host recovery returns cut claims to Ready. Required service replacement must preserve queued work and its owner wake; do not replace durable intake with worker-local queues. |
| Verifier | [`Completion_authority_agent.start`](../../lib/completion_authority_agent.mli) reads immutable verification requests and submitted evidence, delegates judgment and commits through workspace authority. | Submitted evidence access, Task/Goal transition authority, provenance validation, retry classification and human confirmation stay with the host. | Separate model evaluation from final authority before deciding process extraction. A worker may propose a typed verdict, not manufacture a completed Task/Goal or replace the evidence snapshot with current mutable files. |
| Browser Stagehand | The Browser Addon stack already supplies worker dispatch and host model mediation. Its consumer request-schema path is the shared dependency described below. | Host caller/workspace authority, model credentials, profile/context ownership, download grants, artifacts and action receipts remain authoritative. | Reuse the existing Browser worker/model path. Do not add another Stagehand executor. Qualify capability selection and real app interaction under worklist F/H. |

The Required/Optional policy comes from
[`Standalone_lane.obligation`](../../lib/runtime/standalone_lane.ml): HITL Auto
Judge and Board Attention are Required; the other five are Optional. Addon
packaging does not change that policy. Required service replacement must first
admit a successor or preserve an explicit recoverable unavailable state and all
pending work. A manifest flag cannot override the host's service obligation.

## Other execution and resource boundaries

| Surface | Current source and caller | Boundary to preserve |
| --- | --- | --- |
| Fusion | [`Fusion_orchestrator`](../../lib/fusion/fusion_orchestrator.mli), [`Fusion_run_registry`](../../lib/fusion_core/fusion_run_registry.mli), and `addons/fusion-compute`, `fusion-results`, `fusion-report` | Existing packages need composition/use qualification, not another packaging layer. Host owns immutable run/result identity and explicit delivery obligations; panel answers remain free text. |
| MSX/DOS | `addons/msx-machine`, `dos-machine`, `dos-world`; [`machine-addon-state.md`](../guides/machine-addon-state.md) | Workers already exist. Keep persistent state ownership distinct from worker incarnation; restoring a checkpoint is explicit. Media/save preservation and actual game input remain qualification work. |
| Voice/VST | [`Voice_session_manager`](../../lib/voice/voice_session_manager.mli), [`Keeper_tool_voice_runtime`](../../lib/keeper/keeper_tool_voice_runtime.ml), `addons/vst-phrase` | Separate STT/TTS/realtime/player/device lifetime from host session identity and transcripts. VST Phrase currently observes snapshots; it does not own real audio/VST execution. A persistent session snapshot is not proof that a device/bridge is live. |
| Slack/Discord | [`Server_slack_poll_lane.start`](../../lib/server/server_slack_poll_lane.mli), [`Server_discord_in_process_gateway.start`](../../lib/server/server_discord_in_process_gateway.mli), called from server bootstrap | Keep connector credentials, channel bindings, publication checkpoints and message-send authority on the host. A worker cannot advance a high-water mark before the completed window is published. Polling collection and outbound sends are separate capabilities. |
| Web Search | [`Tool_misc_web_search.handle`](../../lib/tool_misc_web_search.mli), called by [`Tool_misc`](../../lib/tool_misc.ml) and [`Keeper_tool_in_process_runtime`](../../lib/keeper/keeper_tool_in_process_runtime.ml) | Extract provider execution through a host-authorized request; preserve provider order, cancellation, cache identity and sources. Provider credentials must not be copied into an untrusted worker environment. |
| Other packages | `addons/output-statistics`, `value-difference`, `frame-progress`, `web-project`, `wkbl-score-runs`, `operator-quiz`, `msx-observer` | Reuse common discovery/action/Skill contracts. Existence of package files does not prove an installed worker, actual exported tools, or an Agent's successful use. |

## Candle request-schema contract

This is the planned use of the existing Browser grant, not a second schema
broker. Implement it only against a source revision that includes that grant,
either after integration or with an explicit native-stack dependency.

1. The package declares named Grade, Relation and Weights outputs. Their package
   baseline schemas remain mandatory. Only those outputs that need a dynamic
   schema receive `Consumer_request_schema`; an ungranted request is refused.
2. The host captures the domain request and constructs its provider requirement
   with `Candle_appraisal.schema`. `Lane_addon_exact.schema_for_request` checks
   the declared output/grant; `validate_answer` enforces the package baseline
   and the shared partial required-shape check on both new and retained results.
3. A successful common schema check is not a Candle decision. The host runs
   `Candle_appraisal.decode` against the original captured request. Grade must
   belong to that request's policy; Relation uses the closed enum; Weights must
   name exactly the candidate keepers, with no duplicates, integer values within
   the captured range and a positive sum. Additional fields remain errors.
4. Before dispatch, retain the original request, stage, input, schema, selected
   installation/worker identity, configuration/package revisions and trace joins.
   The exact request digest includes schema and original message roles/order.
   Reusing an ID for changed input is refused rather than silently issuing a
   different judgment under an existing receipt.
5. A payout identity alone is not an exact request identity: one payout has
   Grade, multiple per-task Relations and Weights. Retain a distinct durable
   request identity for each intended stage/subrequest; include the Relation's
   original task identity in the host join even when task titles are equal.
   Those audit identifiers are not extra grading evidence. A changed policy or
   replacement input is a new explicit intent, not an overwrite of an old run.
6. Reuse host route resolution/provider admission and the exact runner. Do not
   pass provider secrets to the worker or implement its own HTTP/CLI fallback.
   Feature activation and per-output model selection are independent settings.
7. Retain a typed adapter outcome before waking the payout owner. The common
   broker's `Not_final`/`Final` distinction must survive; missing execution,
   invalid decisions, explicit refusal and uncertain dispatch are different.
   `Candle_appraisal.error` currently has three variants and cannot express all
   these cases. Define and propagate that missing typed boundary before wiring
   production extraction; never flatten `Outcome_unknown` into an automatically
   retryable `Transport_unavailable`.
8. Re-delivery of a retained answer may feed the original host consumer after
   identity and complete domain validation. It must not re-dispatch the model,
   transfer the answer to a replacement worker's request, or duplicate a ledger
   effect. Final settlement still rechecks current Candle availability, policy,
   candidate identity and ledger ownership through `Candle_appraise.settle_one`.

## Lifecycle and evidence required for each extraction

- **Off:** stop admitting new work, preserve pending domain obligations and
  original receipts; record the handling of already accepted calls explicitly.
- **Drain/cancel:** identify the owning request and whether dispatch began.
  Cancellation without a retained terminal result is not proof of no effect.
- **Detach/remove:** record resource release separately from desired Off or a
  lost connection. [`Lane_addon_lifecycle`](../../lib/lane_addon/lane_addon_lifecycle.mli)
  distinguishes cleanup failure, wrong engine/owner and confirmed release.
- **Reconnect:** use a new worker incarnation, retain old results/history, and
  re-admit new work from host-owned durable state. Release only resources whose
  recorded engine/owner matches; never infer cleanup from an incomplete list.
- **Qualification:** show the real worker consuming a new input, the host's
  decoded decision and domain commit, original receipt/history, Dashboard and
  TUI state, then Off/replacement/reconnect with no duplicated effect. Track
  fixture, real provider, installed binary and visible UI evidence separately.

Next implementation unit: Candle durable stage/subrequest ownership and typed
uncertain/refused result adaptation, followed by the actual worker package and
runner integration. Curator follows a completed Candle lifecycle; other domain
authority boundaries need their own implementation decisions and evidence.
