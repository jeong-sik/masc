(** Turn context helpers for keeper tool-call logging.

    The context is carried in a per-run {!cell} created at turn setup and
    threaded to every reader of the same run. RFC-0225 §3.3: the previous
    carrier was a global table keyed by keeper name, so two concurrent runs
    of the same keeper overwrote each other and tool-call rows were logged
    with the wrong run identity (trace_id / keeper_turn_id
    cross-attribution, 2026-06-10 voice incident). A cell per run makes
    attribution correct independently of Owner scheduling. *)

type turn_context =
  { agent_name : string option
  ; turn_kind : Turn_record.turn_kind option
    (* Whether this run is an operator/agent submission or the keeper's own
       autonomous cycle. Both kinds call the same tools with the same
       trace_id, so without this field a reader asking which calls belong to
       a submitted operation has only wall-clock overlap to go on, and a
       concurrent autonomous turn's calls are indistinguishable from the
       submission's (#28977). *)
  ; lane : string option
  ; tool_choice : string option
  ; thinking_enabled : bool option
  ; prompt_fingerprint : string option
  ; trace_id : string option
  ; session_id : string option
  ; turn : int option
  ; keeper_turn_id : int option
  ; task_id : string option
  ; sandbox_profile : string option
  ; sandbox_root : string option
  ; sandbox_roots : string list option
  ; network_mode : string option
  ; runtime_profile : string option
  ; answer_source_ids : string list
      (** Canonical answer input identities owned by this run. This is neither
          model-use proof nor a causal claim about a later Tool effect. *)
  }

type cell
(** Per-run carrier. Reads before the first {!set_turn_context} observe
    the empty context (all fields [None]). *)

val create_cell : unit -> cell

val set_turn_context :
  cell:cell ->
  ?agent_name:string ->
  ?turn_kind:Turn_record.turn_kind ->
  ?lane:string ->
  ?tool_choice:string ->
  ?thinking_enabled:bool ->
  ?prompt_fingerprint:string ->
  ?trace_id:string ->
  ?session_id:string ->
  ?turn:int ->
  ?keeper_turn_id:int ->
  ?task_id:string ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?sandbox_roots:string list ->
  ?network_mode:string ->
  ?runtime_profile:string ->
  ?answer_source_ids:string list ->
  unit ->
  unit

val get_turn_context_record :
  cell:cell ->
  unit ->
  turn_context

val empty_turn_context : turn_context
(** The all-[None] record a fresh cell starts with. Composers that must
    substitute one missing field of an absent context build on this instead
    of minting a partial record by hand. *)

val source_turn_ref : turn_context -> Ids.Turn_ref.t option
(** Original execution observed in one frozen context. Both the trace and
    absolute Keeper turn must be present; logical SDK turn is not a substitute.
    [None] means unobserved and grants no authority. *)

val get_turn_context :
  cell:cell ->
  unit ->
  string option
  * string option
  * bool option
  * string option
  * string option
  * string option
  * int option
  * int option
  * string option
  * string option
  * string option

val runtime_observability_contract_json_for_call :
  keeper_name:string ->
  cell:cell ->
  unit ->
  Yojson.Safe.t

val action_radius_json_for_call :
  cell:cell ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  duration_ms:float ->
  ?error:string ->
  unit ->
  Yojson.Safe.t
