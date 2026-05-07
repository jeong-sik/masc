(** Coord_task_schedule — Scheduling: claim_next, release_stale_claims.

    Extracted from Coord_task to separate scheduling logic (priority queue,
    stale detection, existing-claim preservation) from task CRUD and state
    transitions. *)

open Masc_domain
include Coord_utils
include Coord_state

(** #10421: stable lowercase string label for a [task_status] suitable
    for embedding in JSONL diagnostic events.  Mirrors what the
    [task_transition] from/to fields already use so dashboards can
    join claim-loop diagnostics on identical vocabulary.  Pure; exposed for
    tests. *)
let task_status_label (status : Masc_domain.task_status) : string =
  match status with
  | Todo -> "todo"
  | Claimed _ -> "claimed"
  | InProgress _ -> "in_progress"
  | AwaitingVerification _ -> "awaiting_verification"
  | Done _ -> "done"
  | Cancelled _ -> "cancelled"

let task_is_claim_pool_candidate (task : Masc_domain.task) =
  match task.task_status with
  | Todo ->
      Option.is_none
        (Coord_task.do_not_reclaim_reason_blocks_claim task.do_not_reclaim_reason)
  | Claimed _ | InProgress _ | AwaitingVerification _ | Done _ | Cancelled _ ->
      false

let task_is_primary_claim_pool_candidate (task : Masc_domain.task) =
  match task.task_status with
  | Todo -> Option.is_none task.do_not_reclaim_reason
  | Claimed _ | InProgress _ | AwaitingVerification _ | Done _ | Cancelled _ ->
      false

let task_is_soft_reclaim_candidate (task : Masc_domain.task) =
  match task.task_status, task.do_not_reclaim_reason with
  | Todo, Some reason ->
      Option.is_none (Coord_task.do_not_reclaim_reason_blocks_claim (Some reason))
  | Todo, None
  | Claimed _, _
  | InProgress _, _
  | AwaitingVerification _, _
  | Done _, _
  | Cancelled _, _ ->
      false

type verification_claim_state =
  [ `Pending | `Assigned | `Passed | `Rejected ]

let verification_claim_state_of_status
    (status : Coord_verification_store.request_status) =
  match status with
  | `Pending -> `Pending
  | `Assigned _ -> `Assigned
  | `Completed `Pass -> `Passed
  | `Completed (`Fail _ | `Partial _) ->
      `Rejected

let latest_verification_status_by_task config =
  let latest = Hashtbl.create 16 in
  Coord_verification_store.list_request_headers config.base_path
  |> List.iter (fun (req : Coord_verification_store.request_header) ->
         let state = verification_claim_state_of_status req.status in
         match Hashtbl.find_opt latest req.task_id with
         | Some (latest_created_at, _) when latest_created_at >= req.created_at ->
             ()
         | Some _ | None ->
             Hashtbl.replace latest req.task_id (req.created_at, state));
  latest

let verification_blocks_claim latest_status_by_task (task : Masc_domain.task) =
  match Hashtbl.find_opt latest_status_by_task task.id with
  | Some (_, `Pending)
  | Some (_, `Assigned) -> true
  | Some (_, `Rejected) -> false
  | Some (_, `Passed)
  | None -> false

let task_required_tools (task : Masc_domain.task) =
  match task.contract with
  | Some contract -> contract.required_tools
  | None -> []

let string_list_contains all value =
  List.exists (String.equal value) all

let required_tools_allowed ?agent_tool_names required_tools =
  match required_tools, agent_tool_names with
  | [], _ -> true
  | _ :: _, None -> true
  | required, Some allowed ->
      List.for_all (string_list_contains allowed) required

let underscore_name name =
  String.map (function '-' -> '_' | c -> c) name

let hyphen_name name =
  String.map (function '_' -> '-' | c -> c) name

let keeper_name_from_agent_name agent_name =
  let trimmed = String.trim agent_name in
  if
    String.starts_with ~prefix:"keeper-" trimmed
    && String.ends_with ~suffix:"-agent" trimmed
    && String.length trimmed > 13
  then Some (String.sub trimmed 7 (String.length trimmed - 13))
  else if String.ends_with ~suffix:"-agent" trimmed && String.length trimmed > 6
  then Some (String.sub trimmed 0 (String.length trimmed - 6))
  else None

let agent_record_keeper_name config ~agent_name =
  let agent_file =
    Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
  in
  if path_exists config agent_file then
    match read_agent_with_repair config agent_file with
    | Ok { meta = Some { keeper_name = Some name; _ }; _ } ->
        let name = String.trim name in
        if name = "" then None else Some name
    | Ok _ | Error _ -> None
  else None

let keeper_receipt_candidate_names config ~agent_name =
  let base =
    [ agent_record_keeper_name config ~agent_name
    ; keeper_name_from_agent_name agent_name
    ; Some agent_name
    ]
    |> List.filter_map Fun.id
  in
  base
  |> List.concat_map (fun name ->
       let trimmed = String.trim name in
       if trimmed = "" then []
       else
         [ trimmed; safe_filename trimmed; underscore_name trimmed; hyphen_name trimmed ])
  |> List.sort_uniq String.compare

let directory_exists path =
  try Sys.file_exists path && Sys.is_directory path with Sys_error _ -> false

let directory_entries path =
  try Sys.readdir path |> Array.to_list with Sys_error _ -> []

let receipt_persistence_surface = "coord_task_schedule_receipt"

let report_receipt_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      (Atomic.get Coord_hooks.persistence_read_drop_fn)
        ~surface:receipt_persistence_surface
        ~reason)
    ~surface:receipt_persistence_surface
    ~reason
    ~path
    ~detail

let jsonl_files_under base_dir =
  if not (directory_exists base_dir) then []
  else
    directory_entries base_dir
    |> List.filter_map (fun month ->
         let month_dir = Filename.concat base_dir month in
         if directory_exists month_dir then Some month_dir else None)
    |> List.concat_map (fun month_dir ->
         directory_entries month_dir
         |> List.filter (String.ends_with ~suffix:".jsonl")
         |> List.map (Filename.concat month_dir))

let last_nonempty_line path =
  try
    let input = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () ->
         let rec loop last =
           match input_line input with
           | line ->
               let trimmed = String.trim line in
               loop (if trimmed = "" then last else Some trimmed)
           | exception End_of_file -> last
         in
         loop None)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error detail ->
      report_receipt_read_drop
        ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
        ~path
        ~detail;
      None

let latest_json_in_receipt_dir base_dir =
  jsonl_files_under base_dir
  |> List.sort (fun a b -> compare b a)
  |> List.find_map (fun path ->
       match last_nonempty_line path with
       | None -> None
       | Some line -> (
           try Some (Yojson.Safe.from_string line)
           with Yojson.Json_error detail ->
             report_receipt_read_drop
               ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
               ~path
               ~detail;
             None))

let json_member_path path json =
  List.fold_left
    (fun current key -> Yojson.Safe.Util.member key current)
    json
    path

let json_raw_string_path path json =
  match json_member_path path json with
  | `String value -> Some (String.trim value)
  | _ -> None

let json_string_path path json =
  json_raw_string_path path json
  |> Option.map String.lowercase_ascii

let receipt_sort_key json =
  match json_raw_string_path [ "recorded_at" ] json with
  | Some value -> value
  | None ->
      Option.value ~default:"" (json_raw_string_path [ "ended_at" ] json)

let latest_execution_receipt_json config ~agent_name =
  let keeper_root = Filename.concat (masc_root_dir config) "keepers" in
  keeper_receipt_candidate_names config ~agent_name
  |> List.filter_map (fun keeper_name ->
       let base_dir =
         Filename.concat
           (Filename.concat keeper_root keeper_name)
           "execution-receipts"
       in
       latest_json_in_receipt_dir base_dir)
  |> List.sort (fun a b -> compare (receipt_sort_key b) (receipt_sort_key a))
  |> List.find_opt (fun _ -> true)

let json_string_list key json =
  match Yojson.Safe.Util.member key json with
  | `List items ->
      List.filter_map
        (function
          | `String value ->
              let trimmed = String.trim value in
              if trimmed = "" then None else Some trimmed
          | _ -> None)
        items
  | _ -> []

let latest_receipt_blocks_required_tool_claim config ~agent_name ~required_tools =
  match latest_execution_receipt_json config ~agent_name with
  | None -> false
  | Some receipt ->
      let operator_reason =
        json_string_path [ "operator_disposition_reason" ] receipt
      in
      let tool_contract_result =
        json_string_path [ "tool_contract_result" ] receipt
      in
      let tool_requirement =
        json_string_path [ "tool_surface"; "tool_requirement" ] receipt
      in
      let tools_used = json_string_list "tools_used" receipt in
      let degraded_contract =
        match tool_contract_result with
        | Some
            ( "violated"
            | "unknown"
            | "satisfied_by_deterministic_fallback"
            | "needs_execution_progress"
            | "missing_required_tool_use"
            | "passive_only"
            | "claim_only_after_owned_task"
            | "tool_surface_mismatch"
            | "no_tool_capable_provider" ) ->
            true
        | Some _ | None -> false
      in
      let visible_tools =
        json_string_list "requested_tools" receipt
        @ json_string_list "canonical_tools" receipt
        @ tools_used
      in
      let required_tool_visible =
        List.exists
          (fun required_tool -> string_list_contains visible_tools required_tool)
          required_tools
      in
      (operator_reason = Some "tool_required_no_tools"
       || degraded_contract
       || (tool_requirement = Some "required" && tools_used = []))
      && not required_tool_visible

let active_task_assignees_by_task_id backlog =
  let table = Hashtbl.create (List.length backlog.tasks) in
  List.iter
    (fun (task : Masc_domain.task) ->
      match task.task_status with
      | Claimed { assignee; _ } | InProgress { assignee; _ } ->
          Hashtbl.replace table task.id assignee
      | Todo | AwaitingVerification _ | Done _ | Cancelled _ -> ())
    backlog.tasks;
  table

let agent_current_task_matches_assignments active_task_assignees ~agent_name
    task_id =
  match Hashtbl.find_opt active_task_assignees task_id with
  | Some assignee -> String.equal assignee agent_name
  | None -> false

let agent_current_task_matches_backlog backlog ~agent_name task_id =
  let active_task_assignees = active_task_assignees_by_task_id backlog in
  agent_current_task_matches_assignments active_task_assignees ~agent_name
    task_id

let reconcile_agent_current_task_record config ?(touch_last_seen = true)
    ~agent_file ~(agent : Masc_domain.agent) active_task_assignees =
  match agent.current_task with
  | Some task_id
    when not
           (agent_current_task_matches_assignments active_task_assignees
              ~agent_name:agent.name task_id)
    ->
      let updated_status =
        match agent.status with
        | Inactive -> Inactive
        | Active | Busy | Listening -> Active
      in
      let updated =
        {
          agent with
          status = updated_status;
          current_task = None;
          last_seen =
            (if touch_last_seen then now_iso () else agent.last_seen);
        }
      in
      write_json config agent_file (agent_to_yojson updated);
      log_event config (`Assoc [
           ("type", `String "agent_current_task_reconciled");
           ("agent", `String agent.name);
           ("stale_task", `String task_id);
           ("ts", `String (now_iso ()));
         ])
  | Some _ | None -> ()

let reconcile_agent_current_task_with_assignments config ?(touch_last_seen = true)
    ~agent_name active_task_assignees =
  let agent_file =
    Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
  in
  if path_exists config agent_file then
    with_file_lock config agent_file (fun () ->
      match read_agent_with_repair config agent_file with
      | Ok agent ->
          reconcile_agent_current_task_record config ~touch_last_seen ~agent_file
            ~agent active_task_assignees
      | Error msg ->
          Log.Misc.error "agent state reconcile failed: %s" msg)

let reconcile_agent_current_task_with_backlog config ?(touch_last_seen = true)
    ~agent_name backlog =
  let active_task_assignees = active_task_assignees_by_task_id backlog in
  reconcile_agent_current_task_with_assignments config ~touch_last_seen
    ~agent_name active_task_assignees

let reconcile_all_agent_current_tasks_with_backlog config
    ?(touch_last_seen = true) backlog =
  let agents_path = agents_dir config in
  try
    if Sys.file_exists agents_path then (
      let active_task_assignees = active_task_assignees_by_task_id backlog in
      Sys.readdir agents_path
      |> Array.to_list
      |> List.filter (fun name -> Filename.check_suffix name ".json")
      |> List.iter (fun name ->
           Coord_query.safe_yield ();
           let path = Filename.concat agents_path name in
           with_file_lock config path (fun () ->
             match read_agent_with_repair config path with
             | Ok (agent : Masc_domain.agent) ->
                 reconcile_agent_current_task_record config ~touch_last_seen
                   ~agent_file:path ~agent active_task_assignees
             | Error msg ->
                 Log.Misc.error "agent state reconcile failed for %s: %s" name
                   msg)))
  with
  | Sys_error msg ->
      Log.Misc.error "agent state reconcile scan failed: %s" msg

let reconcile_all_agent_current_tasks_with_fresh_backlog
    ?(touch_last_seen = true) config =
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    let backlog = read_backlog config in
    reconcile_all_agent_current_tasks_with_backlog config ~touch_last_seen
      backlog;
    backlog)

(** Claim next highest priority unclaimed task.
    Optional [exclude_task_ids] prevents re-claiming known bad tasks in the
    same loop run.  Optional [task_filter] lets callers scope eligible work
    while the backlog lock is held.

    Scheduling logic:
    - Preserves any active claim held by this agent; callers must explicitly
      release or finish before claiming different work.
    - Applies starvation prevention: tasks waiting >24h get priority boost
    - Within same effective priority, prefers older tasks (FIFO) *)
let claim_next_r
      config
      ~agent_name
      ?agent_tool_names
      ?(exclude_task_ids = [])
      ?(task_filter = fun _ -> true)
      ()
  =
  let exception Existing_claim of claim_next_result in
  ensure_initialized config;

  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    try
      match read_backlog_r config with
      | Error msg -> Claim_next_error msg
      | Ok backlog ->
      reconcile_agent_current_task_with_backlog config ~agent_name backlog;

      (* #10421: If this agent already holds a Claimed or InProgress task,
         return that task instead of implicitly releasing it.  Automatic
         release caused keeper hot-potato loops: a repeated claim_next call
         could drop InProgress work back to Todo and let another keeper steal
         it before the original owner had a chance to finish.  AwaitingVerification
         is still excluded: it is no longer active implementation work for
         the claimant. *)
      let previous_claim = List.find_opt (fun (t : Masc_domain.task) ->
        match t.task_status with
        | Claimed { assignee; _ } | InProgress { assignee; _ } ->
            String.equal assignee agent_name
        | Todo | AwaitingVerification _ | Done _ | Cancelled _ -> false
      ) backlog.tasks in
      (match previous_claim with
       | None -> ()
       | Some prev ->
           let from_status = task_status_label prev.task_status in
           log_event config (`Assoc [
             ("type", `String "task_claim_next_existing_task");
             ("agent", `String agent_name);
             ("task", `String prev.id);
             ("from_status", `String from_status);
             ("reason", `String "existing_claim_preserved");
             ("ts", `String (now_iso ()));
           ]);
           Log.RoomTask.info
             "task_claim_next preserved existing task: agent=%s task=%s \
              from_status=%s — finish or explicitly release before claiming \
              different work (#10421)"
             agent_name prev.id from_status;
           Coord_task.update_local_agent_state config ~agent_name (fun agent ->
             { agent with status = Busy; current_task = Some prev.id });
           let message =
             Printf.sprintf
               "%s already holds [P%d] %s: %s. ACTION: Resume this task; \
                do not call claim_next again until it is done or explicitly \
                released."
               agent_name prev.priority prev.id prev.title
           in
           raise
             (Existing_claim
                (Claim_next_claimed
                   {
                     task_id = prev.id;
                     title = prev.title;
                     priority = prev.priority;
                     released_task_id = None;
                     message;
                   })));
      let observe_legacy_release () =
        ()
      in
      let released_task_id, working_tasks = None, backlog.tasks in

      (* Starvation prevention: Calculate effective priority
         Tasks waiting >24h get priority boost (-1 per 24h, min 1) *)
      let now = Time_compat.now () in
      (* Reuse canonical UTC parser from Types_core *)
      let parse_time = Types_core.parse_iso8601_opt in
      let effective_priority (task : Masc_domain.task) =
        let age_hours =
          match parse_time task.created_at with
          | Some created -> (now -. created) /. 3600.0
          | None -> 0.0
        in
        let boost = Float.to_int (Float.round (age_hours /. 24.0)) in
        max 1 (task.priority - boost)
      in

      (* Find highest priority (lowest number) unclaimed task
         Within same priority, prefer older tasks (FIFO) *)
      let sorted = List.sort (fun a b ->
        let priority_cmp = compare (effective_priority a) (effective_priority b) in
        if priority_cmp <> 0 then priority_cmp
        else compare a.created_at b.created_at
      ) working_tasks in
      (* Identify blocked Todo tasks for observability *)
      let all_todo = List.filter (fun (t : Masc_domain.task) ->
        t.task_status = Masc_domain.Todo
      ) sorted in
      let blocked_todo = List.filter (fun (t : Masc_domain.task) ->
        Option.is_some
          (Coord_task.do_not_reclaim_reason_blocks_claim t.do_not_reclaim_reason)
      ) all_todo in
      let latest_verification_status = latest_verification_status_by_task config in
      let verification_blocked_todo =
        List.filter (verification_blocks_claim latest_verification_status) all_todo
      in
      if blocked_todo <> [] then
        log_event config
          (`Assoc [
             ("type", `String "task_claim_next_skip_blocked");
             ("agent", `String agent_name);
             ("blocked", `Int (List.length blocked_todo));
             ("ts", `String (now_iso ()));
           ]);
      if verification_blocked_todo <> [] then
        log_event config
          (`Assoc [
             ("type", `String "task_claim_next_skip_verification");
             ("agent", `String agent_name);
             ("blocked", `Int (List.length verification_blocked_todo));
             ("ts", `String (now_iso ()));
           ]);

      let primary_unclaimed =
        List.filter task_is_primary_claim_pool_candidate sorted
      in
      let soft_unclaimed =
        List.filter task_is_soft_reclaim_candidate sorted
      in
      let unclaimed =
        List.filter task_is_claim_pool_candidate sorted
      in
      (* Also exclude the just-released task: the agent is moving on,
         re-claiming the same task would be a no-op loop. *)
      let blocked_ids =
        List.map (fun (t : Masc_domain.task) -> t.id) blocked_todo
        @ List.map (fun (t : Masc_domain.task) -> t.id) verification_blocked_todo
        |> List.sort_uniq String.compare
      in
      let all_excluded = match released_task_id with
        | Some rid -> rid :: (blocked_ids @ exclude_task_ids)
        | None -> blocked_ids @ exclude_task_ids
      in
      let receipt_blocks_task (task : task) =
        match agent_tool_names with
        | Some _ -> false
        | None ->
          let required_tools = task_required_tools task in
          required_tools <> []
          && latest_receipt_blocks_required_tool_claim config ~agent_name
               ~required_tools
      in
      if Option.is_none agent_tool_names
         && List.exists (fun task -> task_required_tools task <> []) unclaimed
      then
        log_event config
          (`Assoc [
             ("type", `String "task_claim_next_required_tools_unknown_surface");
             ("agent", `String agent_name);
             ("candidate_count", `Int (List.length
                (List.filter (fun task -> task_required_tools task <> []) unclaimed)));
             ("ts", `String (now_iso ()));
           ]);
      let required_tool_claim_allowed (task : task) =
        let required_tools = task_required_tools task in
        required_tools_allowed ?agent_tool_names required_tools
        && not (receipt_blocks_task task)
      in
      let required_tool_excluded =
        List.filter
          (fun (t : task) ->
             (not (List.mem t.id all_excluded))
             && task_filter t
             && not (required_tool_claim_allowed t))
          unclaimed
      in
      if required_tool_excluded <> [] then
        log_event config (`Assoc [
          ("type", `String "task_claim_next_skip_required_tools");
          ("agent", `String agent_name);
          ("blocked", `Int (List.length required_tool_excluded));
          ("receipt_blocked", `Bool (List.exists receipt_blocks_task required_tool_excluded));
          ("agent_tool_names_known", `Bool (Option.is_some agent_tool_names));
          ("ts", `String (now_iso ()));
        ]);
      let effective_task_filter task =
        task_filter task && required_tool_claim_allowed task
      in
      let task_filter_excluded =
        List.filter
          (fun (t : task) -> (not (List.mem t.id all_excluded)) && not (task_filter t))
          unclaimed
      in
      let eligible_from candidates =
        List.filter
          (fun (t : task) ->
             (not (List.mem t.id all_excluded)) && effective_task_filter t)
          candidates
      in
      let primary_eligible = eligible_from primary_unclaimed in
      let eligible =
        match primary_eligible with
        | _ :: _ -> primary_eligible
        | [] -> eligible_from soft_unclaimed
      in

      (* Helper: clear agent current_task and reset status after a legacy
         released_task_id path when no replacement task can be claimed. Delegates to
         [Coord_task.update_local_agent_state] so the agent-file write
         holds [with_file_lock] on the agent file itself, matching the
         discipline used by [Coord_task] transitions (PR #6634). *)
      let clear_agent_state_after_release () =
        match released_task_id with
        | Some _ ->
            Coord_task.update_local_agent_state config ~agent_name (fun agent ->
              { agent with status = Active; current_task = None })
        | None -> ()
      in

      match all_todo, eligible with
      | [], _ ->
          (* Even if we released a task, there may be nothing else to claim.
             Write the release if it happened. *)
          (match released_task_id with
           | Some _ ->
               let new_backlog = {
                 tasks = working_tasks;
                 last_updated = now_iso ();
                 version = backlog.version + 1;
               } in
               write_backlog config new_backlog;
               observe_legacy_release ()
           | None -> ());
          clear_agent_state_after_release ();
          Claim_next_no_unclaimed
      | _ :: _, [] ->
          (match released_task_id with
           | Some _ ->
               let new_backlog = {
                 tasks = working_tasks;
                 last_updated = now_iso ();
                 version = backlog.version + 1;
               } in
               write_backlog config new_backlog;
               observe_legacy_release ()
           | None -> ());
          clear_agent_state_after_release ();
          Claim_next_no_eligible
            {
              excluded_count =
                List.length all_excluded
                + List.length task_filter_excluded
                + List.length required_tool_excluded;
            }
      | _ :: _, task :: _ ->
          (* Claim this task *)
          let new_tasks = List.map (fun (t : task) ->
            if t.id = task.id then
              let t =
                t
                |> Coord_task.clear_soft_do_not_reclaim_reason
                |> Coord_task.clear_stale_worktree_binding
              in
              {
                t with
                task_status =
                  Claimed { assignee = agent_name; claimed_at = now_iso () };
              }
            else t
          ) working_tasks in

          let new_backlog = {
            tasks = new_tasks;
            last_updated = now_iso ();
            version = backlog.version + 1;
          } in
          write_backlog config new_backlog;

          (* Update agent status — takes [with_file_lock] on the
             agent file via [Coord_task.update_local_agent_state] to
             keep the record consistent with concurrent
             [Coord_agent.update_agent_r] or other task transitions
             that hold the agent-file lock (PR #6634). *)
          Coord_task.update_local_agent_state config ~agent_name (fun agent ->
            { agent with status = Busy; current_task = Some task.id });

          (* No broadcast — log_event + emit_task_activity below are sufficient. *)
          (match released_task_id with
           | Some rid ->
               Coord_task.emit_task_activity config ~agent_name ~task_id:rid
                 ~kind:(Event_kind.Task.to_string Event_kind.Task.Released)
                 ~payload:(`Assoc [ ("task_id", `String rid) ]);
               observe_legacy_release ()
           | None -> ());
          Coord_task.emit_task_activity config ~agent_name ~task_id:task.id
            ~kind:(Event_kind.Task.to_string Event_kind.Task.Claimed)
            ~payload:
              (`Assoc
                [
                  ("task_id", `String task.id);
                  ("title", `String task.title);
                  ("priority", `Int task.priority);
                ]);

          log_event config (`Assoc [
            ("type", `String "task_claim_next");
            ("agent", `String agent_name);
            ("task", `String task.id);
            ("priority", `Int task.priority);
            ("ts", `String (now_iso ()));
          ]);
          Coord_task.observe_task_transition config ~agent_name ~task_id:task.id
            ~transition:Masc_domain.Claim
            ~details:
              (Coord_task.task_transition_details ~from_status:Masc_domain.Todo
                 ~to_status:
                   (Masc_domain.Claimed
                      { assignee = agent_name; claimed_at = now_iso () })
                 ());
          (try
             (Atomic.get Coord_hooks.claim_post_provision_fn) config ~agent_name
               ~task_id:task.id
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               Coord_hooks.observe_claim_post_provision_failure
                 ~site:"claim_next" ~agent_name ~task_id:task.id exn);

          let message = match released_task_id with
            | Some rid ->
                Printf.sprintf "%s released %s, then claimed [P%d] %s: %s"
                  agent_name rid task.priority task.id task.title
            | None ->
                Printf.sprintf "%s auto-claimed [P%d] %s: %s"
                  agent_name task.priority task.id task.title
          in
          Claim_next_claimed {
            task_id = task.id;
            title = task.title;
            priority = task.priority;
            released_task_id;
            message;
          }
    with
    | Existing_claim result -> result
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Claim_next_error (Printexc.to_string e)
  )

(** Claim next highest priority unclaimed task (legacy string API). *)
let claim_next config ~agent_name =
  match claim_next_r config ~agent_name () with
  | Claim_next_claimed { message; _ } -> message
  | Claim_next_no_unclaimed -> "No unclaimed tasks. ACTION: Stop task-checking — nothing to claim."
  | Claim_next_no_eligible { excluded_count } ->
      Printf.sprintf
        "No eligible unclaimed tasks. ACTION: Stop task-checking — blocked/excluded=%d."
        excluded_count
  | Claim_next_error e -> Printf.sprintf "Error: %s" e

(** Release stale task claims older than [ttl_seconds].
    A Claimed or InProgress task whose assignee has no recent heartbeat
    (per the zombie threshold) is considered stale.
    Returns list of (task_id, assignee) pairs that were released. *)
let release_stale_claims config ~ttl_seconds =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    match read_backlog_r config with
    | Error msg ->
        Log.Orchestrator.error
          "[stale-claims] skipping backlog mutation due to read failure: %s"
          msg;
        []
    | Ok backlog ->
        let now_str = now_iso () in
        let now_f = Time_compat.now () in
        let age_seconds_json ts =
          `Float (max 0.0 (now_f -. ts))
        in
        let stale_tasks = ref [] in
        let updated_tasks = List.map (fun (task : task) ->
          match task.task_status with
          | Claimed { assignee; claimed_at } ->
              let ts = parse_iso8601 ~default_time:(now_f -. ttl_seconds -. 1.0) claimed_at in
              if now_f -. ts > ttl_seconds then begin
                stale_tasks := (task.id, assignee) :: !stale_tasks;
                log_event config (`Assoc [
                  ("type", `String "stale_claim_released");
                  ("task_id", `String task.id);
                  ("assignee", `String assignee);
                  ("age_s", age_seconds_json ts);
                  ("ts", `String now_str);
                ]);
                { task with
                  task_status = Todo;
                  worktree = None;
                }
              end else task
          | InProgress { assignee; started_at } ->
              let ts = parse_iso8601 ~default_time:(now_f -. ttl_seconds -. 1.0) started_at in
              if now_f -. ts > ttl_seconds then begin
                stale_tasks := (task.id, assignee) :: !stale_tasks;
                log_event config (`Assoc [
                  ("type", `String "stale_inprogress_released");
                  ("task_id", `String task.id);
                  ("assignee", `String assignee);
                  ("age_s", age_seconds_json ts);
                  ("ts", `String now_str);
                ]);
                { task with
                  task_status = Todo;
                  worktree = None;
                }
              end else task
          | AwaitingVerification _ -> task  (* leave alone; awaiting verifier *)
        | Todo | Done _ | Cancelled _ -> task
      ) backlog.tasks in
        if !stale_tasks <> [] then begin
          let updated_backlog = { tasks = updated_tasks; last_updated = now_str; version = backlog.version + 1 } in
          write_backlog config updated_backlog
        end;
        List.rev !stale_tasks
  )
