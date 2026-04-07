open Keeper_types
open Keeper_exec_shared

let keeper_task_result_json = function
  | Ok msg -> Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "result", `String msg ])
  | Error e ->
    Yojson.Safe.to_string
      (`Assoc [ "ok", `Bool false; "error", `String (Types.masc_error_to_string e) ])
;;

let handle_keeper_task_tool
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match name with
  | "keeper_tasks_list" ->
    let status_filter = Safe_ops.json_string_opt "status" args in
    let include_done = Safe_ops.json_bool ~default:false "include_done" args in
    Room.list_tasks ?status:status_filter ~include_done config
  | "keeper_tasks_audit" ->
    let orphans = Room.audit_orphan_tasks config in
    let items =
      List.map
        (fun (task, assignee) ->
           let task : Types.task = task in
           `Assoc
             [ "task_id", `String task.id
             ; "title", `String task.title
             ; "assignee", `String assignee
             ; "status", `String (Types.string_of_task_status task.task_status)
             ])
        orphans
    in
    let action_hint =
      if orphans = [] then
        "ACTION: STOP calling keeper_tasks_audit — no orphans found. Move on to other work or end your turn."
      else
        Printf.sprintf "ACTION: %d orphan(s) found. Use keeper_task_force_release or keeper_task_force_done to resolve, then STOP re-auditing."
          (List.length orphans)
    in
    Yojson.Safe.to_string
      (`Assoc [ "orphan_count", `Int (List.length orphans); "orphans", `List items;
                "action", `String action_hint ])
  | "keeper_task_force_release" ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let reason = Safe_ops.json_string ~default:"" "reason" args in
    if task_id = ""
    then error_json "task_id is required. Use the task_id from keeper_tasks_list or keeper_tasks_audit."
    else (
      let agent = keeper_agent_sender ~meta in
      let _ =
        Room.broadcast
          config
          ~from_agent:agent
          ~content:
            (Printf.sprintf
               "Force-releasing task %s (reason: %s)"
               task_id
               (if reason = "" then "no reason given" else reason))
      in
      keeper_task_result_json
        (Room.force_release_task_r config ~agent_name:agent ~task_id ()))
  | "keeper_task_force_done" ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let notes = Safe_ops.json_string ~default:"" "notes" args in
    if task_id = ""
    then error_json "task_id is required. Use the task_id from keeper_tasks_list or keeper_tasks_audit."
    else
      keeper_task_result_json
        (Room.force_done_task_r
           config
           ~agent_name:(keeper_agent_sender ~meta)
           ~task_id
           ~notes
           ())
  | "keeper_broadcast" ->
    let message = Safe_ops.json_string ~default:"" "message" args |> String.trim in
    if message = ""
    then error_json "message is required. Good: message='Build complete, all tests pass.'."
    else (
      let _ =
        Room.broadcast config ~from_agent:(keeper_agent_sender ~meta) ~content:message
      in
      Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "broadcast", `String message ]))
  | "keeper_task_claim" ->
    let result = Room.claim_next config ~agent_name:meta.agent_name in
    Yojson.Safe.to_string (`Assoc [ "result", `String result ])
  | "keeper_task_done" ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let result_text = Safe_ops.json_string ~default:"" "result" args |> String.trim in
    if task_id = ""
    then error_json "task_id is required. Use the task_id you got from keeper_task_claim."
    else
      keeper_task_result_json
        (Room.force_done_task_r
           config
           ~agent_name:(keeper_agent_sender ~meta)
           ~task_id
           ~notes:(if result_text = "" then "" else result_text)
           ())
  | other -> error_json ~fields:[ "tool", `String other ] "unknown_task_tool"
;;

