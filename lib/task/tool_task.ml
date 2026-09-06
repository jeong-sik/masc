(* Helpers, context, add_task, batch_add, claim, claim_next, release —
   extracted to [Tool_task_handlers] (godfile decomp). *)

open Tool_args
include Tool_task_handlers

module Workspace = Workspace_core

let workflow_rejection_result
      ~tool_name
      ~start_time
      ?rule_id
      ?recoverable
      ?extra_fields
      message
  =
  let data =
    Workflow_rejection_payload.payload
      ?rule_id
      ?recoverable
      ?extra_fields
      message
  in
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    ~data
    (Yojson.Safe.to_string data)

let missing_live_task_transition_rejection ~tool_name ~start_time ctx ~task_id
      ~action_s =
  sync_owner_current_task_binding ctx;
  sync_planning_current_task_with_owned_task ctx;
  task_log_warn ~task_id
    "transition rejected stale task_id for action=%s agent=%s; reconciled current task bindings"
    action_s ctx.agent_name;
  workflow_rejection_result
    ~tool_name
    ~start_time
    ~rule_id:"stale_task_id_not_found"
    ~extra_fields:
      [ "task_id", `String task_id
      ; "action", `String action_s
      ; "requested_agent", `String ctx.agent_name
      ; "stale_context", `Bool true
      ]
    (Printf.sprintf
       "Task %s is absent from the live backlog; cleared stale current-task \
        bindings and suppressed transition action=%s."
       task_id action_s)

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

and handle_transition ~tool_name ~start_time ctx args =
  (* Underscore-prefixed keys (e.g. "_agent_name") are internal protocol markers
     injected by the HTTP transport and dashboard client for identity
     propagation. They are consumed upstream in Client_identity and must not
     trigger the strict-schema "Unknown argument(s)" rejection here. *)
  let is_internal_marker k =
    String.length k > 0 && Char.equal k.[0] '_'
  in
  let unknown = match args with
    | `Assoc kvs ->
      List.filter
        (fun (k, _) ->
          (not (is_internal_marker k))
          && not (List.mem k transition_known_args))
        kvs
    | _ -> []
  in
  if Stdlib.List.length unknown > 0 then
    let names = String.concat ", " (List.map fst unknown) in
    (* RFC-0189: schema-rejection — operator passed an unknown
       argument name. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      (Printf.sprintf "Unknown argument(s): %s. Valid: %s"
        names (String.concat ", " transition_known_args))
  else
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response ~tool_name ~start_time (Error e)
  | Ok task_id ->
  let action_raw = get_string args "action" "" in
  if String.equal action_raw "" then
    (* RFC-0189: required-field violation. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      (Printf.sprintf "action is required (%s)" (String.concat ", " Masc_domain.valid_task_action_strings))
  else
  match Masc_domain.task_action_of_string action_raw with
  | Error msg ->
      (* RFC-0189: caller passed an unknown action enum value. *)
      Tool_result.error
        ~failure_class:Tool_result.Workflow_rejection
        ~tool_name ~start_time msg
  | Ok action ->
  let action_s = Masc_domain.task_action_to_string action in
  let notes = get_string args "notes" "" in
  let reason = get_string args "reason" "" in
  let handoff_context =
    parse_handoff_context ~agent_name:ctx.agent_name ~action args
  in
  let expected_version = get_int_opt args "expected_version" in
  let tasks = Workspace.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks in
  match task_opt with
  | None ->
    missing_live_task_transition_rejection
      ~tool_name
      ~start_time
      ctx
      ~task_id
      ~action_s
  | Some task_before ->
  let release_owner_mismatch_rejection =
    match action, task_opt with
    | Masc_domain.Release, Some task ->
      (match Workspace.task_assignee_of_status task.task_status with
       | Some assignee
         when not (Workspace.same_task_actor ctx.config assignee ctx.agent_name) ->
         let status = Masc_domain.task_status_to_string task.task_status in
         let message =
           Printf.sprintf
             "Task %s is %s and owned by %s; %s cannot release it."
             task_id
             status
             assignee
             ctx.agent_name
         in
         Some
           (workflow_rejection_result
              ~tool_name
              ~start_time
              ~rule_id:"task_release_requires_current_owner"
              ~extra_fields:
                [ "task_id", `String task_id
                ; "task_status", `String status
                ; "current_assignee", `String assignee
                ; "requested_agent", `String ctx.agent_name
                ]
              message)
       | Some _ | None -> None)
    | Masc_domain.Release, None -> None
    | ( Masc_domain.Claim
      | Masc_domain.Start
      | Masc_domain.Done_action
      | Masc_domain.Cancel
      | Masc_domain.Submit_for_verification ), _ -> None
  in
  (* The terminal-verdict no-op branch is gone with the verdict actions: an agent
     can no longer request approve/reject here, so there is no verdict-on-terminal
     case to absorb. *)
  match release_owner_mismatch_rejection with
  | Some result -> result
  | None ->
  let completion_state_error =
    if (=) action Masc_domain.Done_action then
      completion_state_error ~task_id ~agent_name:ctx.agent_name ~task_opt
    else
      None
  in
  match completion_state_error with
  | Some err ->
    log_task_transition_failed ~agent_name:ctx.agent_name err;
    let message = Masc_domain.masc_error_to_string err in
    let rule_id =
      (* Exhaustive, no catch-all: [completion_state_error] returns only
         [Task] errors and only four of the five constructors, but a [_] arm
         here would silently absorb a newly added variant into the generic
         rule id instead of failing to compile. *)
      match err with
      | Masc_domain.Task (Masc_domain.Task_error.NotClaimed _) ->
        Some "task_done_requires_claimed_or_started"
      | Masc_domain.Task (Masc_domain.Task_error.AlreadyClaimed _) ->
        Some "task_done_requires_current_owner"
      | Masc_domain.Task (Masc_domain.Task_error.InvalidState _) ->
        Some "task_done_invalid_lifecycle_state"
      | Masc_domain.Task (Masc_domain.Task_error.NotFound _) ->
        Some "task_done_task_not_found"
      | Masc_domain.Task (Masc_domain.Task_error.InvalidId _)
      | Masc_domain.Agent _
      | Masc_domain.Auth _
      | Masc_domain.System _
      | Masc_domain.RateLimitExceeded _
      | Masc_domain.CacheError _ -> Some "task_done_lifecycle_rejected"
    in
    workflow_rejection_result
      ~tool_name
      ~start_time
      ?rule_id
      ?recoverable:
        (match rule_id with
         | Some "task_done_requires_claimed_or_started" -> Some true
         | _ -> None)
      message
  | None ->
  match handoff_context with
  | Error error ->
      (* RFC-0189: handoff_context parse error — caller passed
         malformed payload. *)
      Tool_result.error
        ~failure_class:Tool_result.Workflow_rejection
        ~tool_name ~start_time error
  | Ok handoff_context ->
  if (=) action Masc_domain.Release && strict_release_requires_handoff task_opt
     && Option.is_none handoff_context
  then
    (* RFC-0189: strict-release-without-handoff = workflow violation. *)
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      "Strict task release requires handoff_context.summary"
  else
  let action_s = Masc_domain.task_action_to_string action in
  (* [now () -. 60.0] used to stand in whenever the status carried no usable
     start: Todo, Done, Cancelled, an unparseable timestamp, or no task at all.
     That number reaches [Metrics_store_eio] as [started_at] and the average is
     computed as [completed_at -. started_at], so every such task recorded a
     duration of exactly one minute — indistinguishable in the aggregate from a
     task that really took one. Absence is [None] and the metric is not
     recorded (#29355). *)
  let started_at_of value = Masc_domain.parse_iso8601_opt value in
  let collaborators_of assignee =
    if (not (String.equal assignee "")) && not (String.equal assignee ctx.agent_name)
    then [ assignee ]
    else []
  in
  let (started_at_actual, collaborators_from_task) = match task_opt with
    | Some t -> (match t.task_status with
        | Masc_domain.InProgress { started_at; assignee } ->
            (started_at_of started_at, collaborators_of assignee)
        | Masc_domain.Claimed { claimed_at; assignee } ->
            (started_at_of claimed_at, collaborators_of assignee)
        (* [started_at] is the producer's original work start, preserved across
           submission and rejection (see task_status). [submitted_at] is when
           verification began, so using it reported the wait, not the work. *)
        | Masc_domain.AwaitingVerification { started_at; assignee; _ } ->
            (started_at_of started_at, collaborators_of assignee)
        | Masc_domain.Todo
        | Masc_domain.Done _
        | Masc_domain.Cancelled _ -> (None, []))
    | None -> (None, [])
  in
  let completion_owner =
    match task_opt with
    | Some task ->
      Option.value
        ~default:ctx.agent_name
        (Masc_domain.task_assignee_of_status task.task_status)
    | None -> ctx.agent_name
  in
  let completion_collaborators =
    (* The approve branch is gone: it added the approving agent to the task's
       collaborator set, which only made sense while a keeper could be the
       verifier. A completion authority is not an agent and never joins it. *)
    collaborators_from_task
  in
  (* The pre-transition verification_id capture (issue #7543) is gone with the
     approve/reject actions: no agent transition consumes an AwaitingVerification
     state any more, so there is nothing to snapshot before it changes. *)
  let result =
    Workspace.transition_task_r
      ctx.config
      ~agent_name:ctx.agent_name
      ~task_id
      ~action
      ?expected_version
      ~notes
      ~reason
      ?handoff_context
      ()
  in
  Result.iter
    (fun _ ->
       sync_owner_current_task_binding ctx;
       sync_planning_current_task_with_owned_task ctx)
    result;
  (* Notify A2A subscribers on successful transition *)
  (match result with
   | Ok _ ->
        (* Notification harness: push task transition to all active sessions *)
       (Atomic.get Workspace_hooks.push_task_event_fn)
          ~event_type:"masc/task_transition"
          ~details:[
            ("task_id", `String task_id);
            ("action", `String action_s);
            ("agent_name", `String ctx.agent_name);
          ];
   | Error err ->
       log_task_transition_failed ~agent_name:ctx.agent_name err);
  (* Record metrics *)
  (* A metric with no real start cannot say how long the work took, and an
     invented one is worse than a missing row: it lands in the same average.
     The transition itself is already recorded elsewhere; this hook exists to
     measure duration. *)
  (match result, action, started_at_actual with
   | Ok _, Masc_domain.Done_action, Some started_at ->
       (Atomic.get Workspace_hooks.record_task_metric_fn)
         ctx.config
         ~agent_id:completion_owner
         ~task_id
         ~started_at
         ~completed_at:(Some (Time_compat.now ()))
         ~success:true
         ~error_message:None
         ~collaborators:completion_collaborators
         ~handoff_from:None
         ~handoff_to:None
   | Ok _, Masc_domain.Cancel, Some started_at ->
       (Atomic.get Workspace_hooks.record_task_metric_fn)
         ctx.config
         ~agent_id:ctx.agent_name
         ~task_id
         ~started_at
         ~completed_at:(Some (Time_compat.now ()))
         ~success:false
         ~error_message:
           (Some
              (* The same sentence the transition recorded: the caller may have
                 stated it in handoff_context.summary rather than in [reason].
                 A committed stop of a started task always carries one — the
                 transition refuses a cancel claim without it — so the bare
                 label only ever names the event. *)
              (match Masc_domain.stated_reason ~reason:(Some reason) ~handoff_context with
               | Some reason -> reason
               | None -> "Cancelled"))
         ~collaborators:collaborators_from_task
         ~handoff_from:None
         ~handoff_to:None
  | Ok _, (Masc_domain.Done_action | Masc_domain.Cancel), None
  | Ok _, (Masc_domain.Claim | Masc_domain.Start | Masc_domain.Submit_for_verification
            | Masc_domain.Release), _
  | Error _, _, _ -> ());
  let transition_result_to_response = function
    | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState message)) ->
      workflow_rejection_result
        ~tool_name
        ~start_time
        ~rule_id:"task_transition_invalid_state"
        ~recoverable:false
        ~extra_fields:
          [ "task_id", `String task_id
          ; "action", `String action_s
          ; "requested_agent", `String ctx.agent_name
          ]
        (Printf.sprintf "Invalid task state: %s" message)
    | result -> result_to_response ~tool_name ~start_time result
  in
  transition_result_to_response result

let handle_update_priority ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  let priority = get_int args "priority" 3 in
  match Workspace.update_priority ctx.config ~task_id ~priority with
  | Ok (Workspace.Updated { task_id; old_priority; new_priority }) ->
    Tool_result.ok
      ~tool_name
      ~start_time
      (Printf.sprintf "Task %s priority: P%d → P%d" task_id old_priority new_priority)
  | Ok (Workspace.Not_found { task_id }) ->
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name
      ~start_time
      (Printf.sprintf "Task %s not found" task_id)
  | Error Workspace.Not_initialized ->
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name
      ~start_time
      "MASC workspace is not initialized"
  | Error (Workspace.Backlog_read_error detail) ->
    Tool_result.error
      ~failure_class:Tool_result.Dependency_unavailable
      ~tool_name
      ~start_time
      (Printf.sprintf "Task priority update could not read the backlog: %s" detail)
  | Error (Workspace.Backlog_write_error detail) ->
    Tool_result.error
      ~failure_class:Tool_result.Dependency_unavailable
      ~tool_name
      ~start_time
      (Printf.sprintf "Task priority update could not commit the backlog: %s" detail)
  | Error (Workspace.Lock_error error) ->
    Tool_result.error
      ~failure_class:Tool_result.Dependency_unavailable
      ~tool_name
      ~start_time
      (Printf.sprintf "Task priority update could not acquire the backlog lock: %s"
         (Masc_domain.masc_error_to_string error))
  | Error (Workspace.Unexpected_error detail) ->
    Tool_result.error
      ~failure_class:Tool_result.Runtime_failure
      ~tool_name
      ~start_time
      (Printf.sprintf "Task priority update failed: %s" detail)

let handle_tasks ~tool_name ~start_time ctx args =
  let include_done = get_bool args "include_done" false in
  let include_cancelled = get_bool args "include_cancelled" false in
  let status =
    match args |> Json_util.assoc_member_opt "status" |> Option.value ~default:`Null with
    | `String s when not (String.equal s "") -> Some s
    | _ -> None
  in
  Tool_result.ok ~tool_name ~start_time
    (Workspace.list_tasks
       ctx.config
       ~include_done
       ~include_cancelled
       ?status)

(* Walks newest-first and stops once [limit] events satisfy [keep], so [limit]
   counts the events a caller asked for. Counting raw lines instead made the
   caller filter afterwards, and no line budget expresses "this task's newest
   N": the budget fills with whatever the workspace last did, and a task whose
   events sit further back drops out of its own history entirely.

   Parsing happens here because [keep] asks about fields, and deciding on the
   raw line would mean matching an id as a substring of unparsed JSON —
   a different event's payload can carry that text. Malformed lines are skipped
   rather than counted: they are not events the caller asked for. *)
let read_matching_events config ~limit ~keep =
  let events_dir = Filename.concat (Workspace.masc_dir config) "events" in
  if not (Sys.file_exists events_dir) then []
  else
    let month_dirs =
      Sys.readdir events_dir |> Array.to_list |> List.sort compare |> List.rev
    in
    let collected = ref [] in
    let remaining = ref limit in
    let read_lines path =
      Fs_compat.load_file path
      |> String.split_on_char '\n'
      |> List.filter (fun s -> s <> "")
    in
    let add_lines path =
      if !remaining <= 0 then ()
      else
        let rec take = function
          | [] -> ()
          | line :: rest ->
            if !remaining > 0 then begin
              (match Yojson.Safe.from_string line with
               | json when keep json ->
                 collected := json :: !collected;
                 decr remaining
               | _ -> ()
               | exception Yojson.Json_error _ -> ());
              take rest
            end
        in
        take (List.rev (read_lines path))
    in
    List.iter
      (fun month ->
         if !remaining > 0 then
           let month_path = Filename.concat events_dir month in
           if Sys.file_exists month_path && Sys.is_directory month_path then
             let files =
               Sys.readdir month_path
               |> Array.to_list
               |> List.sort compare
               |> List.rev
             in
             List.iter
               (fun file ->
                  if !remaining > 0 then
                    let path = Filename.concat month_path file in
                    if Sys.file_exists path then add_lines path)
               files)
      month_dirs;
    List.rev !collected

let task_history_events_json (config : Workspace.config) ~task_id ~limit =
  let matches_task json =
    let task = Json_util.get_string json "task" in
    let task_id_field = Json_util.get_string json "task_id" in
    match task, task_id_field with
    | Some t, _ when String.equal t task_id -> true
    | _, Some t when String.equal t task_id -> true
    | _ -> false
  in
  `List (read_matching_events config ~limit ~keep:matches_task)

let handle_task_history ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  let limit = get_int args "limit" 50 in
  Tool_result.make_ok
    ~tool_name
    ~start_time
    ~data:(task_history_events_json ctx.config ~task_id ~limit)
    ()

include Tool_task_schemas
(* Dispatch function *)
(* The masc_* task tools route on Tool_name.Task_name, so a constructor added
   there is a compile error here rather than a tool that is advertised and then
   answers "unknown". keeper_task_claim is in the keeper_* namespace and is not
   part of that vocabulary. *)
let dispatch_task_name ?created_by ctx ~name ~args ~start = function
  | Tool_name.Task_name.Add_task ->
    handle_add_task ?created_by ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Batch_add_tasks ->
    handle_batch_add_tasks ?created_by ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Task_history ->
    handle_task_history ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Task_set_goal ->
    handle_set_goal ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Tasks -> handle_tasks ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Transition ->
    handle_transition ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Update_priority ->
    handle_update_priority ~tool_name:name ~start_time:start ctx args
;;

let dispatch_internal ?created_by ctx ~name ~args =
  let start = Time_compat.now () in
  match Tool_name.Task_name.of_string name with
  | Some task_name ->
    Some (dispatch_task_name ?created_by ctx ~name ~args ~start task_name)
  | None ->
    (match name with
     | "keeper_task_claim" ->
       let task_id = get_string args "task_id" "" in
       if String.equal task_id ""
       then Some (handle_claim_next ~tool_name:name ~start_time:start ctx args)
       else Some (handle_claim ~tool_name:name ~start_time:start ctx args)
     | _ -> None)

let dispatch ctx ~name ~args =
  dispatch_internal ctx ~name ~args
;;

let dispatch_for_keeper ~created_by ctx ~name ~args =
  dispatch_internal ~created_by ctx ~name ~args
;;
