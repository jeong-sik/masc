type 'a context = 'a Tool_operator.context

val operator_dir : Workspace.config -> string
val pending_confirms_path : Workspace.config -> string
val trace_id : string -> string
val normalized_actor : context_actor:string -> string option -> string
val operator_judge_runtime_json : Workspace.config -> Yojson.Safe.t

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

type target =
  { target_type : Operator_action_constants.target_type
  ; target_id : string option
  }

val register_target_gate :
  (Workspace.config -> target -> (unit, string) result) -> unit

val preview_of_pending_confirm : pending_confirm -> Yojson.Safe.t
val pending_confirm_to_yojson : pending_confirm -> Yojson.Safe.t
val pending_confirm_of_yojson : Yojson.Safe.t -> (pending_confirm, string) result
val raw_pending_confirms_result :
  Workspace.config -> (pending_confirm list, string) result
val raw_pending_confirms : Workspace.config -> pending_confirm list
val write_pending_confirms :
  Workspace.config -> pending_confirm list -> (unit, string) result
val pending_confirm_expired : pending_confirm -> bool
val read_pending_confirms_result :
  Workspace.config -> (pending_confirm list, string) result
val read_pending_confirms : Workspace.config -> pending_confirm list
val upsert_pending_confirm :
  Workspace.config -> pending_confirm -> (unit, string) result
val remove_pending_confirm : Workspace.config -> string -> (unit, string) result
val remove_pending_confirms_by_target :
  Workspace.config -> target_type:string -> target_id:string option -> (int, string) result
val remove_pending_confirms_by_typed_target :
  Workspace.config -> target -> (int, string) result
val normalize_pending_confirm_actor_filter : string option -> string option
val pending_confirm_scope_of_entries : ?actor:string -> pending_confirm list -> pending_confirm_scope
val pending_confirm_scope : ?actor:string -> Workspace.config -> pending_confirm_scope
val pending_confirms_json : ?actor:string -> Workspace.config -> Yojson.Safe.t
val available_actions : available_action list
val available_action_to_yojson : available_action -> Yojson.Safe.t
val available_actions_json : Yojson.Safe.t
val pending_confirm_summary_json_of_scope : pending_confirm_scope -> Yojson.Safe.t
val pending_confirm_summary_json : ?actor:string -> Workspace.config -> Yojson.Safe.t
val pending_confirm_envelope_json : ?actor:string -> Workspace.config -> Yojson.Safe.t
