(** Admission evidence, never current mutation authority. *)
type goal = { goal_id : string; phase : Goal_phase.t; criterion : Goal_store.criterion }
type source_error =
  | Goal_links_unavailable of string
  | Goal_source_unavailable of Goal_store_unavailable.t
  | Linked_goal_missing of string
type t =
  | No_task
  | Task_source_unavailable of string
  | Task of { task_id : Keeper_id.Task_id.t; goals : (goal list, source_error) result }
val capture : config:Workspace.config -> (Keeper_id.Task_id.t option, string) result -> t
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, Keeper_memory_os_types.wire_error) result
