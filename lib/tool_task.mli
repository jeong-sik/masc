
(** Tool_task - Core task CRUD operations *)

type context = {
  config: Coord.config;
  agent_name: string;
  sw: Eio.Switch.t option;
}

val handle_add_task : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_batch_add_tasks : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_claim : ?agent_tool_names:string list -> tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_claim_next : ?agent_tool_names:string list -> tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_release : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_done : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_cancel_task : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_transition : ?agent_tool_names:string list -> tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_update_priority : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_tasks : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val handle_task_history : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t
val task_history_events_json :
  Coord.config -> task_id:string -> limit:int -> Yojson.Safe.t

val dispatch :
  ?agent_tool_names:string list ->
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.t option

val schemas : Masc_domain.tool_schema list

val completion_notes_example : string
(** Concrete example of accepted completion notes. Referenced in the
    rejection message so the keeper sees the expected density, not
    just "describe actual work". See #8688. *)

val completion_rejection_message : ?allow_force:bool -> string -> string
(** Build the wire-level message returned when the anti-rationalization
    gate rejects a completion. Always embeds
    [completion_notes_example]. Exposed for regression tests that lock
    in the example substring. *)

(** [build_claim_observation_payload ~now ~agent_name ~task_id] builds the
    downstream collaboration-observation fragment for a successful
    [masc_claim_next] write/readback result. MASC uses a central coordination
    store here, so CRDT-specific [logical_clock] and [convergence_delay_ms]
    are left null. *)
val build_claim_observation_payload :
  now:float -> agent_name:string -> task_id:string -> Yojson.Safe.t

(** [is_cross_model_verdict result] is [true] iff [result] has both
    [generator_cascade = Some g] and [evaluator_cascade] non-empty,
    and [g <> evaluator_cascade].

    Inclusion criteria align exactly with
    {!Eval_calibration.calibration_stats} so the live SSE event and
    the aggregated [cross_model_rate] never disagree on whether a
    given verdict counts. *)
val is_cross_model_verdict : Anti_rationalization.review_result -> bool

(** [build_verdict_sse_payload ~now ~task_id ~req ~result] builds the
    [verdict_recorded] SSE envelope for a finished review.

    Pure function — no IO, no broadcast, no logging. Exposed so that
    the payload contract (field names, nullability, [cross_model]
    semantics) can be exercised by unit tests without touching
    Sse.broadcast or the review pipeline. *)
val build_verdict_sse_payload :
  now:float ->
  task_id:string ->
  req:Anti_rationalization.review_request ->
  result:Anti_rationalization.review_result ->
  Yojson.Safe.t
