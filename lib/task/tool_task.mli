
(** Tool_task - Core task CRUD operations *)

type context = {
  config: Workspace_core.config;
  agent_name: string;
  sw: Eio.Switch.t option;
}

val handle_add_task : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_batch_add_tasks : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_claim : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_claim_next : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_release : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_done :
  ?task_list_projection:Tool_capability_projection.task_list ->
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_cancel_task : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_transition :
  ?task_list_projection:Tool_capability_projection.task_list ->
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_update_priority : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_tasks : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_task_history : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val task_history_events_json :
  Workspace_core.config -> task_id:string -> limit:int -> Yojson.Safe.t

val dispatch :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.result option

(** Keeper-model dispatch projects semantic task-list guidance to
    [keeper_tasks_list] instead of the external [masc_tasks] transport name. *)
val dispatch_for_keeper :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.result option

val schemas : Masc_domain.tool_schema list

val completion_notes_example : string
(** Concrete example of accepted completion notes. Referenced in the
    rejection message so the agent sees the expected density, not
    just "describe actual work". See #8688. *)

val completion_rejection_message : ?allow_force:bool -> string -> string
(** Build the wire-level message returned when the anti-rationalization
    gate rejects a completion. Always embeds
    [completion_notes_example]. Exposed for regression tests that lock
    in the example substring. *)

(** [build_claim_observation_payload ~now ~agent_name ~task_id ~scope_widened]
    builds the downstream collaboration-observation fragment for a successful
    [keeper_task_claim] write/readback result. [scope_widened] records whether
    the claim widened the agent's goal scope. MASC uses a central workspace
    store here, so CRDT-specific [logical_clock] and [convergence_delay_ms]
    are left null. *)
val build_claim_observation_payload :
  now:float ->
  agent_name:string ->
  task_id:string ->
  scope_widened:bool ->
  Yojson.Safe.t

(** [is_cross_runtime_verdict result] is [true] iff [result] has both
    [generator_runtime = Some g] and [evaluator_runtime] non-empty,
    and [g <> evaluator_runtime].

    Inclusion criteria align exactly with
    {!Eval_calibration.calibration_stats} so the live SSE event and
    the aggregated [cross_runtime_rate] never disagree on whether a
    given verdict counts. *)
val is_cross_runtime_verdict : Anti_rationalization.review_result -> bool

(** [build_verdict_sse_payload ~now ~task_id ~req ~result] builds the
    [verdict_recorded] SSE envelope for a finished review.

    Pure function — no IO, no broadcast, no logging. Exposed so that
    the payload contract (field names, nullability, [cross_runtime]
    semantics) can be exercised by unit tests without touching
    Sse.broadcast or the review pipeline. *)
val build_verdict_sse_payload :
  now:float ->
  task_id:string ->
  req:Anti_rationalization.review_request ->
  result:Anti_rationalization.review_result ->
  Yojson.Safe.t
