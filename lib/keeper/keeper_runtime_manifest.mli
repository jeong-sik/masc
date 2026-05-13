(** Durable per-turn decision manifest for keeper runtime diagnosis.

    The manifest is intentionally narrower than execution receipts.  Receipts
    describe what happened after a turn; manifest rows record the routing and
    context decisions that explain why the turn took that path. *)

type event_kind =
  | Turn_started
  | Phase_gate_decided
  | Cascade_routed
  | Pre_dispatch_blocked
  | Tool_surface_selected
  | Provider_lane_resolved
  | Provider_attempt_started
  | Provider_attempt_finished
  | Context_injected
  | Context_compacted
  | State_snapshot_sidecar_saved
  | Event_bus_correlated
  | Memory_injected
  | Memory_flushed
  | Checkpoint_loaded
  | Checkpoint_saved
  | Receipt_appended
  | Turn_finished

type links = {
  receipt_path : string option;
  checkpoint_path : string option;
  tool_call_log_path : string option;
}

type t = {
  schema_version : int;
  ts : string;
  keeper_name : string;
  agent_name : string option;
  trace_id : string;
  generation : int option;
  keeper_turn_id : int option;
  oas_turn_count : int option;
  event : event_kind;
  cascade_name : string option;
  provider_kind : string option;
  model_id : string option;
  status : string;
  decision : Yojson.Safe.t;
  links : links;
}

type turn_context = {
  manifest_keeper_name : string;
  manifest_agent_name : string option;
  manifest_trace_id : string;
  manifest_generation : int option;
  manifest_keeper_turn_id : int option;
}

val schema_version : int
val all_event_kinds : event_kind list
val event_kind_to_string : event_kind -> string
val event_kind_of_string : string -> event_kind option
val safe_segment : string -> string

val make :
  ?ts:string ->
  keeper_name:string ->
  ?agent_name:string ->
  trace_id:string ->
  ?generation:int ->
  ?keeper_turn_id:int ->
  ?oas_turn_count:int ->
  event:event_kind ->
  ?cascade_name:string ->
  ?provider_kind:string ->
  ?model_id:string ->
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?receipt_path:string ->
  ?checkpoint_path:string ->
  ?tool_call_log_path:string ->
  unit ->
  t

val make_for_context :
  turn_context ->
  event:event_kind ->
  ?oas_turn_count:int ->
  ?cascade_name:string ->
  ?provider_kind:string ->
  ?model_id:string ->
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?receipt_path:string ->
  ?checkpoint_path:string ->
  ?tool_call_log_path:string ->
  unit ->
  t

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result

val execution_receipt_path_for_today :
  Coord.config -> keeper_name:string -> string

(** [.masc/keepers/<keeper>/runtime-manifests]. *)
val base_dir : Coord.config -> keeper_name:string -> string

(** [.masc/keepers/<keeper>/runtime-manifests/<trace_id>.jsonl].
    [trace_id] is sanitized as a path segment. *)
val path_for_trace : Coord.config -> keeper_name:string -> trace_id:string -> string

val append_to_path : string -> t -> (unit, string) result
val append : Coord.config -> t -> (unit, string) result
val append_best_effort : ?site:string -> Coord.config -> t -> unit

val append_unfinished_provider_attempt_finished_best_effort :
  ?site:string ->
  Coord.config ->
  turn_context ->
  status:string ->
  error:string ->
  ?exception_kind:string ->
  unit ->
  unit
