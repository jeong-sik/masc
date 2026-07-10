(** Post-turn memory write series for [Keeper_agent_run.run_turn].

    Extracts the durable post-turn side-effect stages from Step 8 body
    (tool-result promotion, episodic record, draft-skill projection, and
    compaction) into a typed job boundary. Quality-metrics JSONL append remains
    synchronous because it targets the separate decision log.

    Each durable sub-stage has an explicit succeeded/skipped/failed outcome in
    the terminal receipt. Non-cancel exceptions become failed stage evidence;
    [Eio.Cancel.Cancelled] is re-raised so the inflight job can replay. *)

type submission_outcome =
  | Durable of Keeper_memory_job_store.job
  | Not_durable

val run :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  generation:int ->
  turn:int ->
  oas_turn_count:int ->
  response_text:string ->
  actual_tools:string list ->
  librarian_checkpoint:Agent_sdk.Checkpoint.t ->
  tool_results_snapshot:Yojson.Safe.t list option ->
  post_turn_t0:float ->
  runtime_id:string ->
  inference_telemetry:Agent_sdk.Types.inference_telemetry option ->
  unit ->
  submission_outcome
(** Run the full post-turn memory series.

    [post_turn_t0] is the timestamp (from [Time_compat.now ()]) taken
    immediately before this function is called; it is used to compute
    the [post_turn_ms] metric written to the decision log.

    [inference_telemetry] is [result.response.telemetry] from the OAS
    result; it is optional because some providers do not emit telemetry.

    The OAS checkpoint is reduced to the librarian's bounded message window
    before durable admission; replay therefore uses the exact turn snapshot
    without duplicating unbounded conversation/tool state. *)

val execute_job : Keeper_memory_lane.execute
(** Durable job handler installed once by server bootstrap. *)
