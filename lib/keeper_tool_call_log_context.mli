(** Turn context helpers for keeper tool-call logging.

    The context is carried in a per-run {!cell} created at turn setup and
    threaded to every reader of the same run. RFC-0225 §3.3: the previous
    carrier was a global table keyed by keeper name, so two concurrent runs
    of the same keeper overwrote each other and tool-call rows were logged
    with the wrong run identity (trace_id / keeper_turn_id
    cross-attribution, 2026-06-10 voice incident). A cell per run makes
    attribution correct independently of turn admission. *)

type turn_context =
  { agent_name : string option
  ; lane : string option
  ; tool_choice : string option
  ; thinking_enabled : bool option
  ; thinking_budget : int option
  ; prompt_fingerprint : string option
  ; trace_id : string option
  ; session_id : string option
  ; generation : int option
  ; turn : int option
  ; keeper_turn_id : int option
  ; task_id : string option
  ; sandbox_profile : string option
  ; sandbox_root : string option
  ; allowed_paths : string list option
  ; network_mode : string option
  ; runtime_profile : string option
  }

type cell
(** Per-run carrier. Reads before the first {!set_turn_context} observe
    the empty context (all fields [None]). *)

val create_cell : unit -> cell

val set_turn_context :
  cell:cell ->
  ?agent_name:string ->
  ?lane:string ->
  ?tool_choice:string ->
  ?thinking_enabled:bool ->
  ?thinking_budget:int ->
  ?prompt_fingerprint:string ->
  ?trace_id:string ->
  ?session_id:string ->
  ?generation:int ->
  ?turn:int ->
  ?keeper_turn_id:int ->
  ?task_id:string ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?allowed_paths:string list ->
  ?network_mode:string ->
  ?runtime_profile:string ->
  unit ->
  unit

val get_turn_context_record :
  cell:cell ->
  unit ->
  turn_context

val get_turn_context :
  cell:cell ->
  unit ->
  string option
  * string option
  * bool option
  * int option
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
  success:bool ->
  duration_ms:float ->
  ?error:string ->
  unit ->
  Yojson.Safe.t
