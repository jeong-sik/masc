(** Tool_task - Core task CRUD operations *)

type tool_result = bool * string

type context = {
  config: Coord.config;
  agent_name: string;
  sw: Eio.Switch.t option;
}

val handle_add_task : context -> Yojson.Safe.t -> tool_result
val handle_batch_add_tasks : context -> Yojson.Safe.t -> tool_result
val handle_claim : ?agent_tool_names:string list -> context -> Yojson.Safe.t -> tool_result
val handle_claim_next : ?agent_tool_names:string list -> context -> Yojson.Safe.t -> tool_result
val handle_release : context -> Yojson.Safe.t -> tool_result
val handle_done : context -> Yojson.Safe.t -> tool_result
val handle_cancel_task : context -> Yojson.Safe.t -> tool_result
val handle_transition : ?agent_tool_names:string list -> context -> Yojson.Safe.t -> tool_result
val handle_update_priority : context -> Yojson.Safe.t -> tool_result
val handle_tasks : context -> Yojson.Safe.t -> tool_result
val handle_task_history : context -> Yojson.Safe.t -> tool_result
val task_history_events_json :
  Coord.config -> task_id:string -> limit:int -> Yojson.Safe.t

val dispatch :
  ?agent_tool_names:string list ->
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  tool_result option

val schemas : Types.tool_schema list

val completion_notes_example : string
(** Concrete example of accepted completion notes. Referenced in the
    rejection message so the keeper sees the expected density, not
    just "describe actual work". See #8688. *)

val completion_rejection_message : ?allow_force:bool -> string -> string
(** Build the wire-level message returned when the anti-rationalization
    gate rejects a completion. Always embeds
    [completion_notes_example]. Exposed for regression tests that lock
    in the example substring. *)

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
