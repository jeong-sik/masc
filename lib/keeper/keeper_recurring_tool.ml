(** Keeper_recurring_tool — keeper recurring task management tool handler.

    RFC-0314: Keeper Recurring Producer. Provides list and remove operations
    for keeper-bound recurring tasks. *)

open Keeper_recurring

let dispatch ~agent_name ~name ~args =
  let open Tool_result in
  let start_time = Time_compat.now () in
  let ok msg = ok ~tool_name:name ~start_time msg in
  let err msg = error ~tool_name:name ~start_time msg in
  match name with
  | "masc_recurring_list" ->
    (match args with
     | `Assoc fields ->
       let keeper_name =
         match List.assoc_opt "keeper_name" fields with
         | Some (`String s) -> s
         | _ -> agent_name
       in
       (match list ~keeper_name with
        | Ok tasks ->
          let json_tasks =
            `List
              (List.map
                 (fun (t : Keeper_recurring.recurring_task) ->
                   `Assoc
                     [ "id", `String t.id
                     ; "label", `String t.label
                     ; "interval_sec", `Int t.interval_sec
                     ; "enabled", `Bool t.enabled
                     ; "last_run_ts", `String t.last_run_ts
                     ; "run_count", `Int t.run_count
                     ; "failure_count", `Int t.failure_count
                     ])
                 tasks)
          in
          ok (`Assoc [ "tasks", json_tasks ])
        | Error e -> err ("Failed to list recurring tasks: " ^ e))
     | _ -> err "masc_recurring_list requires an object argument")
  | "masc_recurring_add" ->
    (match args with
     | `Assoc fields ->
       let keeper_name =
         match List.assoc_opt "keeper_name" fields with
         | Some (`String s) -> s
         | _ -> agent_name
       in
       (match List.assoc_opt "label" fields, List.assoc_opt "interval_sec" fields with
        | Some (`String label), Some (`Int interval_sec) ->
          let action = Broadcast label in
          (match add ~keeper_name ~label ~interval_sec ~action with
           | Ok task ->
             ok
               (`Assoc
                 [ "id", `String task.id
                 ; "label", `String task.label
                 ; "interval_sec", `Int task.interval_sec
                 ; "enabled", `Bool task.enabled
                 ])
           | Error `Duplicate ->
             err ("Recurring task with label '" ^ label ^ "' already exists for " ^ keeper_name))
        | None, _ -> err "masc_recurring_add requires a string 'label' field"
        | _, None -> err "masc_recurring_add requires an int 'interval_sec' field"
        | Some (`String _), Some _ -> err "interval_sec must be an integer"
        | _ -> err "masc_recurring_add: invalid field types")
     | _ -> err "masc_recurring_add requires an object argument")
  | "masc_recurring_remove" ->
    (match args with
     | `Assoc fields ->
       (match List.assoc_opt "id" fields with
        | Some (`String id) ->
          (match remove ~id with
           | Ok () -> ok (`Assoc [ "removed", `String id ])
           | Error `Not_found -> err ("Recurring task not found: " ^ id)
           | Error `Not_owner -> err ("Task " ^ id ^ " does not belong to this keeper"))
        | _ -> err "masc_recurring_remove requires a string 'id' field")
     | _ -> err "masc_recurring_remove requires an object argument")
  | _ -> None
;;
