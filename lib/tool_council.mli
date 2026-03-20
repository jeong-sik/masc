(** Council tools - Multi-agent debate and consensus system *)

type context = {
  base_path: string;
  agent_name: string;
  room_config: Room.config option;
}

type result = bool * string

val schemas : Types.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option

(** Execute a governance action (add_task, start_operation, set_param).
    Exposed for automated execution. *)
val execute_action :
  context ->
  Council.Governance_v2.case_record ->
  Council.Governance_v2.execution_order ->
  (Council.Governance_v2.execution_order, string) Stdlib.result

(** Handle governance feed requests.  Exposed for HTTP routes. *)
val handle_governance_feed : context -> Yojson.Safe.t -> result

(** Handle runtime params listing.  Exposed for HTTP routes. *)
val handle_runtime_params : context -> Yojson.Safe.t -> result

val definitions : Yojson.Safe.t list
