type 'a context = {
  config : Coord.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
  mcp_session_id : string option;
}

val option_to_json : ('a -> Yojson.Safe.t) -> 'a option -> Yojson.Safe.t
val string_option_to_json : string option -> Yojson.Safe.t
val operator_dir : Coord.config -> string
val pending_confirms_path : Coord.config -> string
val trace_id : string -> string
val normalized_actor : context_actor:string -> string option -> string
val operator_judge_runtime_json : Coord.config -> Yojson.Safe.t

type pending_confirm = {
  token : string;
  trace_id : string;
  actor : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  payload : Yojson.Safe.t;
  delegated_tool : string;
  created_at : string;
  expires_at : string option;
}

type pending_confirm_scope = {
  actor_filter : string option;
  all_entries : pending_confirm list;
  visible_entries : pending_confirm list;
  hidden_entries : pending_confirm list;
}

type available_action = {
  action_type : string;
  tool_name : string;
  target_type : string;
  description : string;
  confirm_required : bool;
}

val preview_of_pending_confirm : pending_confirm -> Yojson.Safe.t
val pending_confirm_to_yojson : pending_confirm -> Yojson.Safe.t
val pending_confirm_of_yojson : Yojson.Safe.t -> (pending_confirm, string) result
val raw_pending_confirms : Coord.config -> pending_confirm list
val write_pending_confirms : Coord.config -> pending_confirm list -> unit
val pending_confirm_expired : pending_confirm -> bool
val read_pending_confirms : Coord.config -> pending_confirm list
val upsert_pending_confirm : Coord.config -> pending_confirm -> unit
val remove_pending_confirm : Coord.config -> string -> unit
val remove_pending_confirms_by_target :
  Coord.config -> target_type:string -> target_id:string option -> int
val normalize_pending_confirm_actor_filter : string option -> string option
val pending_confirm_scope_of_entries : ?actor:string -> pending_confirm list -> pending_confirm_scope
val pending_confirm_scope : ?actor:string -> Coord.config -> pending_confirm_scope
val pending_confirms_json : ?actor:string -> Coord.config -> Yojson.Safe.t
val available_actions : available_action list
val available_action_to_yojson : available_action -> Yojson.Safe.t
val available_actions_json : Yojson.Safe.t
val pending_confirm_summary_json_of_scope : pending_confirm_scope -> Yojson.Safe.t
val pending_confirm_summary_json : ?actor:string -> Coord.config -> Yojson.Safe.t
val pending_confirm_envelope_json : ?actor:string -> Coord.config -> Yojson.Safe.t
