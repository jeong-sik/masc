(** Read-only portrait and equipment view for the current Keeper. *)

val equipment_to_json : Keeper_portrait_look.equipment -> Yojson.Safe.t
(** The equipment as the tool reports it. Exposed so a test can compare the
    tool's output against {!Keeper_portrait_look.equipment_of_name} without
    duplicating the constructor-to-string mapping. *)

val handle
  :  keeper_name:string
  -> tool_name:string
  -> start_time:Tool_timing.started
  -> config:Workspace.config
  -> args:Yojson.Safe.t
  -> Tool_result.result
