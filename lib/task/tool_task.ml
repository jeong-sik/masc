(* Helpers, context, add_task, batch_add, claim, claim_next, release —
   extracted to [Tool_task_handlers] (godfile decomp). *)

open Tool_args
include Tool_task_handlers

module Workspace = Workspace_core

let task_log_info ~task_id fmt =
  Stdlib.Format.ksprintf
    (fun message -> Log.Task.info "task_id=%s %s" task_id message)
    fmt

let task_log_warn ~task_id fmt =
  Stdlib.Format.ksprintf
    (fun message -> Log.Task.warn "task_id=%s %s" task_id message)
    fmt

let task_log_error ~task_id fmt =
  Stdlib.Format.ksprintf
    (fun message -> Log.Task.error "task_id=%s %s" task_id message)
    fmt

let missing_live_task_transition_rejection ~tool_name ~start_time ctx ~task_id ~action_s =
  sync_owner_current_task_binding ctx;
  sync_planning_current_task_with_owned_task ctx;
  task_log_warn ~task_id
    "transition rejected stale task_id for action=%s agent=%s; reconciled current task bindings"
    action_s ctx.agent_name;
  Tool_result.error
    ~failure_class:(Some Tool_result.Workflow_rejection)
    ~tool_name
    ~start_time
    (workflow_rejection_payload_json
       ~rule_id:"stale_task_id_not_found"
       ~tool_suggestion:"keeper_tasks_list"
       ~hint:
         "The requested task_id is absent from the live backlog. Do not retry \
          this task_id from memory; refresh keeper_tasks_list or masc_tasks and \
          choose a live task."
       ~scope_policy:"observe"
       ~alternatives:[ "keeper_tasks_list"; "masc_tasks"; "keeper_task_claim" ]
       ~extra_fields:
         [ "task_id", `String task_id
         ; "action", `String action_s
         ; "requested_agent", `String ctx.agent_name
         ; "stale_context", `Bool true
         ]
       (Printf.sprintf
          "Task %s is absent from the live backlog; cleared stale current-task \
           bindings and suppressed transition action=%s."
          task_id action_s))

let rec handle_done ~tool_name ~start_time ctx args =
  let notes = get_string args "notes" "" in
  let evidence_refs = get_string_list args "evidence_refs" in
  handle_transition ~tool_name ~start_time ctx
    (`Assoc
       [
         ("task_id", Json_util.assoc_member_opt "task_id" args |> Option.value ~default:`Null);
         ("action", `String "done");
         ("notes", `String notes);
         ("handoff_context",
          `Assoc
            [
              ("summary", `String notes);
              ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
            ]);
       ])

and handle_cancel_task ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response ~tool_name ~start_time (Error e)
  | Ok task_id ->
  let reason = get_string args "reason" "" in
  let tasks = Workspace.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks in
  let started_at_actual = match task_opt with
    | Some t -> (match t.task_status with
        | Masc_domain.InProgress { started_at; _ } ->
            Masc_domain.parse_iso8601 ~default_time:(Time_compat.now () -. 60.0) started_at
        | Masc_domain.Claimed { started_at; _ } ->
            Masc_domain.parse_iso8601 ~default_time:(Time_compat.now () -. 60.0) started_at
        | _ -> Time_compat.now ())
    | None -> Time_compat.now ()
  in
  let elapsed = Time_compat.now () -. started_at_actual in
  let elapsed_s = string_of_int (int_of_float elapsed) in
  let handoff_context = parse_handoff_context ~agent_name:ctx.agent_name args in
  (match handoff_context with
   | Error e ->
       task_log_error ~task_id "handoff_context parse error: %s" e;
       result_to_response ~tool_name ~start_time (Error e)
   | Ok handoff_context ->
       if strict_release_requires_handoff task_opt && Option.is_none handoff_context
       then
         result_to_response ~tool_name ~start_time
           (Error
              "Strict task release requires handoff_context.summary")
       else
         handle_transition ~tool_name ~start_time ctx
           (`Assoc
              [
                ("task_id", `String task_id);
                ("action", `String "cancel");
                ("reason", `String reason);
                ("handoff_context",
                 (match handoff_context with
                  | Some h -> h
                  | None -> `Null));
              ]))