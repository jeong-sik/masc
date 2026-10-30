(** Full task reads for clients that load list rows before their details. *)
type error = Missing_task_id | Task_not_found | Task_detail_unavailable
val find : tasks:Masc_domain.task list -> goal_task_index:(string, string list) Hashtbl.t
  -> task_id:string -> (Yojson.Safe.t, error) result
val read : config:Workspace.config -> task_id:string option -> (Yojson.Safe.t, error) result
type status = [ `OK | `Bad_request | `Not_found | `Service_unavailable ]
val response : (Yojson.Safe.t, error) result -> status * Yojson.Safe.t

val inspect : config:Workspace.config -> task_id:string option ->
  (Yojson.Safe.t, error) result
(** Independent original Task observation, including archive, unobserved and
    retained deletion evidence. Storage errors remain unavailable; raw cleanup
    diagnostics are not exposed. Existing live detail [read] remains separate. *)
val inspection_response : (Yojson.Safe.t, error) result -> status * Yojson.Safe.t
