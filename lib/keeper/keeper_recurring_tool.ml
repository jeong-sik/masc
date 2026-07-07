(** Keeper_recurring_tool — keeper recurring task management tool handler.

    RFC-0314: Keeper Recurring Producer. Provides list and remove operations
    for keeper-bound recurring tasks. *)

open Keeper_recurring

let dispatch ~agent_name ~name ~args =
  let open Tool_result in
  let start_time = Time_compat.now () in
  let ok data = make_ok ~tool_name:name ~start_time ~data () in
  let err msg = make_err ~tool_name:name ~class_:Workflow_rejection ~start_time msg in
  let keeper_name_of_fields fields =
    match List.assoc_opt "keeper_name" fields with
    | Some (`String s) -> s
    | _ -> agent_name
  in
  let label_exists ~keeper_name ~label =
    list ~keeper_name
    |> List.exists (fun (task : Keeper_recurring.recurring_task) ->
      String.equal task.label label)
  in
  match name with
  | "masc_recurring_list" ->
    (match args with
     | `Assoc fields ->
       let keeper_name = keeper_name_of_fields fields in
       let tasks = list ~keeper_name in
       ok (`Assoc [ "tasks", `List (List.map task_to_json tasks) ])
     | _ -> err "masc_recurring_list requires an object argument")
  | "masc_recurring_add" ->
    (match args with
     | `Assoc fields ->
       let keeper_name = keeper_name_of_fields fields in
       (match List.assoc_opt "label" fields, List.assoc_opt "interval_sec" fields with
        | Some (`String label), Some (`Int interval_sec) ->
          if interval_sec <= 0
          then err "masc_recurring_add requires interval_sec to be greater than zero"
          else if label_exists ~keeper_name ~label
          then err ("Recurring task with label '" ^ label ^ "' already exists for " ^ keeper_name)
          else (
            let action = Broadcast label in
            let task = add ~keeper_name ~label ~interval_sec ~action in
            ok (task_to_json task))
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
          let owned =
            list ~keeper_name:agent_name
            |> List.exists (fun (task : Keeper_recurring.recurring_task) ->
              String.equal task.id id)
          in
          if owned
          then (
            if remove ~id
            then ok (`Assoc [ "removed", `String id ])
            else err ("Recurring task not found: " ^ id))
          else if
            list_all ()
            |> List.exists (fun (task : Keeper_recurring.recurring_task) ->
              String.equal task.id id)
          then err ("Task " ^ id ^ " does not belong to this keeper")
          else err ("Recurring task not found: " ^ id)
        | _ -> err "masc_recurring_remove requires a string 'id' field")
     | _ -> err "masc_recurring_remove requires an object argument")
  | _ -> None
;;
