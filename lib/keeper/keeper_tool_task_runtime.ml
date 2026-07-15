open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

let keeper_task_result_json ?(typed_outcome = (None : Keeper_tool_outcome.t option)) result =
  match result with
  | Ok msg ->
    let typed_fields =
      match typed_outcome with
      | Some t -> [ "typed_outcome", Keeper_tool_outcome.to_json t ]
      | None -> []
    in
    Yojson.Safe.to_string (`Assoc ([ "ok", `Bool true; "result", `String msg ] @ typed_fields))
  | Error e ->
    let typed_fields =
      match typed_outcome with
      | Some t -> [ "typed_outcome", Keeper_tool_outcome.to_json t ]
      | None -> []
    in
    Yojson.Safe.to_string
      (`Assoc ([ "ok", `Bool false; "error", `String (Masc_domain.masc_error_to_string e) ] @ typed_fields))
;;

let workflow_rejection_error_json
      ?(rule_id = "keeper_task_argument_rejected")
      ?(alternatives = [])
      ?(typed_outcome : Keeper_tool_outcome.t option)
      message
  =
  (* RFC-0195 P0: [alternatives] is a typed list of tool names the
     LLM can call instead.  Empty list omits the field; non-empty
     surfaces it directly in the JSON payload so the LLM does not
     have to parse prose [hint] strings to discover next-tool
     candidates.

     RFC-0239 / audit D1: [typed_outcome] carries a top-level
     [typed_outcome] field (extracted by the PostToolUse hook into
     [tool_call_detail.typed_outcome]) so a rejected completion is seen
     as no-progress by the loop detector rather than counted as
     evidence by tool name alone. *)
  let extra_fields =
    match typed_outcome with
    | Some outcome -> [ "typed_outcome", Keeper_tool_outcome.to_json outcome ]
    | None -> []
  in
  Task.Payloads.workflow_rejection_payload_json
    ~rule_id
    ~scope_policy:"observe"
    ~alternatives
    ~extra_fields
    message
;;

let keeper_tool_result_json
      ?(typed_outcome = (None : Keeper_tool_outcome.t option))
      (result : Tool_result.result)
  =
  let has_json_field name fields =
    List.exists (fun (field, _) -> String.equal field name) fields
  in
  let ok = Tool_result.is_success result in
  let message = Tool_result.message result in
  let failure_class_fields =
    match Tool_result.failure_class result with
    | Some cls when not ok ->
      [
        ( "failure_class"
        , `String (Tool_result.tool_failure_class_to_string cls) );
      ]
    | Some _
    | None ->
      []
  in
  let typed_outcome_fields =
    match typed_outcome with
    | Some outcome -> [ "typed_outcome", Keeper_tool_outcome.to_json outcome ]
    | None -> []
  in
  match Tool_result.data result with
  | `Assoc payload_fields ->
    let payload_fields =
      List.fold_left
        (fun acc (key, value) ->
           if has_json_field key acc then acc else acc @ [ key, value ])
        payload_fields
        (failure_class_fields @ typed_outcome_fields)
    in
    Yojson.Safe.to_string (`Assoc payload_fields)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
    Yojson.Safe.to_string
      (`Assoc
         ([ "ok", `Bool ok
          ; (if ok then "result" else "error"), `String message
          ]
          @ failure_class_fields
          @ typed_outcome_fields))
;;

(* Caller-input validation errors carry [Tool_result.Policy_rejection], matching
   the schema-layer [Tool_input_validation] producer. The typed failure class is
   observational metadata; dispatch returns the producer payload unchanged. *)
let validation_error_json message =
  Yojson.Safe.to_string
    (`Assoc
       [ "ok", `Bool false
       ; "error", `String message
       ; ( "failure_class"
         , `String
             (Tool_result.tool_failure_class_to_string
                Tool_result.Policy_rejection) )
       ])
;;

let no_eligible_blocker_summary
      ~blocked_count
      ~verification_blocked_count
      ~scope_excluded_count
  =
  Printf.sprintf
    "Diagnostics: task_scope_or_filter=%d, verification=%d, blocked=%d."
    scope_excluded_count
    verification_blocked_count
    blocked_count
;;


let merge_current_task_id ~(latest : keeper_meta) ~(caller : keeper_meta) =
  {
    latest with
    current_task_id = caller.current_task_id;
    updated_at = caller.updated_at;
  }
;;

let sync_keeper_meta_current_task
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(task_id : string)
  =
  match Keeper_id.Task_id.of_string task_id with
  | Error msg ->
    Log.Keeper.warn ~keeper_name:meta.name
      "could not sync claimed task %s into current_task_id: %s"
      task_id msg
  | Ok current_task_id ->
    let updated_meta =
      { meta with current_task_id = Some current_task_id; updated_at = now_iso () }
    in
    Keeper_registry.update_meta ~base_path:config.base_path meta.name updated_meta;
    (match
       Keeper_meta_store.write_meta_with_merge ~merge:merge_current_task_id config updated_meta
     with
     | Ok () -> ()
     | Error msg ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string WriteMetaFailures)
         ~labels:[("keeper", meta.name); ("phase", "claim_task_id")]
         ();
       Log.Keeper.warn ~keeper_name:meta.name
         "failed to persist claimed current_task_id=%s: %s"
         task_id msg)
;;

(* Cluster sub-dispatch via closed sum type — string [name] is converted
   into [task_op] exactly once at the entry boundary; downstream match
   is exhaustive, so adding a new op forces the compiler to flag every
   site that did not handle it.  Removes the substring-classifier
   anti-pattern (CLAUDE.md §2) from this cluster. *)
type task_op =
  | Tasks_list
  | Tasks_audit
  | Broadcast
  | Task_create
  | Task_claim
  | Task_done

let task_op_of_keeper_tool = function
  | Keeper_tool_name.Tasks_list -> Some Tasks_list
  | Keeper_tool_name.Tasks_audit -> Some Tasks_audit
  | Keeper_tool_name.Broadcast -> Some Broadcast
  | Keeper_tool_name.Task_create -> Some Task_create
  | Keeper_tool_name.Task_claim -> Some Task_claim
  | Keeper_tool_name.Task_done -> Some Task_done
  | _ -> None
;;

let task_op_of_name name =
  match Keeper_tool_name.of_string name with
  | Some tool -> task_op_of_keeper_tool tool
  | None -> None
;;

let parse_keeper_task_done_evidence_refs args =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt "evidence_refs" fields with
     | None ->
       Error
         "evidence_refs is required. Include at least one locally validated \
          base-path artifact, local git commit, or .masc trace/turn/receipt \
          reference."
     | Some (`List refs) ->
       let rec collect acc = function
         | [] ->
           let refs = List.rev acc in
           if refs = []
           then Error "evidence_refs must contain at least one non-empty string."
           else Ok refs
         | `String ref_ :: rest ->
           if Task.Completion_review.blank_evidence_ref ref_
           then Error "evidence_refs must contain only non-empty strings."
           else collect (String.trim ref_ :: acc) rest
         | _ :: _ -> Error "evidence_refs must be an array of non-empty strings."
       in
       collect [] refs
     | Some _ -> Error "evidence_refs must be an array of non-empty strings.")
  | _ -> Error "keeper_task_done arguments must be an object."
;;

let handle_keeper_task_tool_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match task_op_of_name name with
  | None ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json ~fields:[ "tool", `String name ] "unknown_task_tool")
  | Some op ->
    match op with
    | Tasks_list ->
    let status_filter = Safe_ops.json_string_opt "status" args in
    let include_done = Safe_ops.json_bool ~default:false "include_done" args in
    let limit = Safe_ops.json_int ~default:50 "limit" args |> max 1 |> min 100 in
    (match Workspace.read_backlog_r config with
     | Error message ->
       let data =
         `Assoc
           [ "ok", `Bool false
           ; "error", `String message
           ; ( "failure_class"
             , `String
                 (Tool_result.tool_failure_class_to_string
                    Tool_result.Runtime_failure) )
           ]
       in
       Keeper_tool_execution.failure_data
         ~class_:Tool_result.Runtime_failure
         ~message:(Yojson.Safe.to_string data)
         data
     | Ok backlog ->
       let visible (task : Masc_domain.task) =
         match status_filter with
         | Some status ->
           String.equal status (Masc_domain.task_status_to_string task.task_status)
         | None ->
           let is_cancelled =
             match task.task_status with
             | Masc_domain.Cancelled _ -> true
             | ( Masc_domain.Todo
               | Masc_domain.Claimed _
               | Masc_domain.InProgress _
               | Masc_domain.AwaitingVerification _
               | Masc_domain.Done _ ) -> false
           in
           (include_done || not (Masc_domain.task_status_is_done task.task_status))
           && not is_cancelled
       in
       let tasks =
         backlog.tasks
         |> List.filter visible
         |> List.sort (fun (left : Masc_domain.task) right ->
           Int.compare left.priority right.priority)
         |> List.filteri (fun index _ -> index < limit)
       in
       Keeper_tool_execution.success_data
         (`List (List.map Masc_domain.task_to_yojson tasks)))
    | Tasks_audit ->
    let limit = Safe_ops.json_int ~default:20 "limit" args |> max 1 |> min 50 in
    let orphans =
      Workspace.audit_orphan_tasks config
      |> List.filter (fun (_, assignee) -> assignee <> meta.agent_name)
    in
    let orphans = List.filteri (fun i _ -> i < limit) orphans in
    let items =
      List.map
        (fun (task, assignee) ->
           let task : Masc_domain.task = task in
           `Assoc
             [ "task_id", `String task.id
             ; "title", `String task.title
             ; "assignee", `String assignee
             ; "status", `String (Masc_domain.string_of_task_status task.task_status)
             ])
        orphans
    in
    let action_hint =
      if orphans = [] then
        "ACTION: STOP calling keeper_tasks_audit — no orphans found. Move on to other work or end your turn."
      else
        Printf.sprintf "ACTION: %d orphan(s) found. The workspace GC auto-releases zombie tasks — no keeper action required. STOP re-auditing."
          (List.length orphans)
    in
    Keeper_tool_execution.success
      (Yojson.Safe.to_string
         (`Assoc
            [ "orphan_count", `Int (List.length orphans)
            ; "orphans", `List items
            ; "action", `String action_hint
            ; ( "typed_outcome"
              , Keeper_tool_outcome.to_json
                  (if orphans = []
                   then Keeper_tool_outcome.No_progress { reason = No_work_available }
                   else Keeper_tool_outcome.Progress) )
            ]))
    | Broadcast ->
    let message = Safe_ops.json_string ~default:"" "message" args |> String.trim in
    if message = ""
    then
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (error_json "message is required. Good: message='Build complete, all tests pass.'.")
    else (
      let _ =
        Workspace.broadcast config ~from_agent:(keeper_agent_sender ~meta) ~content:message
      in
      Keeper_tool_execution.success
        (Yojson.Safe.to_string
           (`Assoc
              [ "ok", `Bool true
              ; "broadcast", `String message
              ; "typed_outcome", Keeper_tool_outcome.to_json Keeper_tool_outcome.Progress
              ])))
    | Task_create ->
    let title = Safe_ops.json_string ~default:"" "title" args |> String.trim in
    let description = Safe_ops.json_string ~default:"" "description" args |> String.trim in
    let priority = Safe_ops.json_int ~default:3 "priority" args |> max 1 |> min 5 in
    if title = ""
    then
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (validation_error_json "title is required. Provide a clear, actionable task title.")
    else if description = ""
    then
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (validation_error_json
           "description is required. Explain what needs to be done and why.")
    else (
          (* De-duplicated: this keeper-internal path now shares the canonical
             [Task.Args.parse_task_contract] used by the public
             masc_task_create facade. The previous local copy
             [parse_task_contract_arg] had regressed — it rejected an OMITTED
             optional [contract] via a catch-all that conflated None(omitted)
             with a wrong-typed value, which falsely failed keeper_task_create.
             Same lib, no
             dependency wall; the canonical parser handles [None | Some `Null]. *)
          match Task.Args.parse_task_contract args with
           | Error message ->
             Keeper_tool_execution.failure
               ~class_:Tool_result.Policy_rejection
               (validation_error_json message)
           | Ok contract ->
              let result =
                Workspace_task.add_task
                  ?contract
                  config
                  ~title
                  ~priority
                  ~description
              in
              Keeper_tool_execution.success
                (Yojson.Safe.to_string
                   (`Assoc
                     [
                       "ok", `Bool true;
                       "result", `String result;
                       ( "typed_outcome"
                       , Keeper_tool_outcome.to_json Keeper_tool_outcome.Progress );
                     ])))
    | Task_claim ->
    let requested_task_id =
      Safe_ops.json_string ~default:"" "task_id" args |> String.trim
    in
    let explicit_claim_result () =
      let tasks = Workspace.get_tasks_raw config in
      let claim_specific (task : Masc_domain.task) =
        match
          Workspace.claim_task_r
            config
            ~agent_name:meta.agent_name
            ~task_id:requested_task_id
            ()
        with
        | Ok outcome ->
          Workspace.Claim_next_claimed
            { task_id = requested_task_id
            ; title = task.title
            ; priority = task.priority
            ; released_task_id = None
            ; message = outcome.message
            ; scope_widened = false
            }
        | Error e -> Workspace.Claim_next_error (Masc_domain.masc_error_to_string e)
      in
      match
        List.find_opt
          (fun (task : Masc_domain.task) -> String.equal task.id requested_task_id)
          tasks
      with
      | None ->
        Workspace.Claim_next_error
          (Printf.sprintf "unknown task_id: %s" requested_task_id)
      | Some task -> claim_specific task
      in
      let claim_requested_task () =
        if requested_task_id <> "" then
          explicit_claim_result ()
        else
          Workspace.claim_next_r config ~agent_name:meta.agent_name ()
      in
      let result = claim_requested_task () in
    let auto_started_ok = ref false in
    (match result with
     | Workspace.Claim_next_claimed { task_id; _ } ->
       sync_keeper_meta_current_task ~config ~meta ~task_id;
       (* Guard: claim_next_r returns existing active tasks via Existing_claim
          (task_state_schedule.ml:302). When the task is already InProgress,
          dispatching Start produces an InvalidState transition error every
          cycle. Only auto-start when the task is in a pre-start state. *)
       let needs_start =
         let tasks = Workspace.get_tasks_raw config in
         match List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks with
         | Some { task_status = Masc_domain.InProgress _; _ } -> false
         | Some { task_status = Masc_domain.Done _ | Masc_domain.Cancelled _
                 | Masc_domain.AwaitingVerification _; _ } -> false
         | _ -> true
       in
       if needs_start then begin
         let start_result =
           Task.Tool.handle_transition
             ~task_list_projection:Tool_capability_projection.Keeper_tasks_list
             ~tool_name:"keeper_auto_start"
             ~start_time:0.0
             { Task.Tool.config; agent_name = keeper_agent_sender ~meta;
               sw = Eio_context.get_switch_opt () }
             (`Assoc ["task_id", `String task_id; "action", `String "start"])
         in
         auto_started_ok := Tool_result.is_success start_result
       end else
         auto_started_ok := true;
       ()
     | Workspace.Claim_next_no_unclaimed
     | Workspace.Claim_next_no_eligible _
     | Workspace.Claim_next_error _ -> ());
    let message =
      match result with
      | Workspace.Claim_next_claimed { message; _ } ->
          if !auto_started_ok then
            message ^ " Task auto-started — begin work now."
          else message
      | Workspace.Claim_next_no_unclaimed -> "No unclaimed tasks. ACTION: Stop task-checking — nothing to claim."
      | Workspace.Claim_next_no_eligible
          { excluded_count
          ; blocked_count
          ; verification_blocked_count
          ; scope_excluded_count
          ; _
          } ->
        Printf.sprintf
          "No eligible tasks. ACTION: Stop task-checking — blocked/excluded=%d. %s"
          excluded_count
          (no_eligible_blocker_summary
             ~blocked_count
             ~verification_blocked_count
             ~scope_excluded_count)
      | Workspace.Claim_next_error e -> Printf.sprintf "Error: %s" e
    in
    let claimed_task_fields =
      match result with
      | Workspace.Claim_next_claimed
          { task_id; title; priority; released_task_id; scope_widened; _ } ->
          [
              ( "claim_observation",
                Task.Tool.build_claim_observation_payload
                  ~now:(Time_compat.now ()) ~agent_name:meta.agent_name
                  ~task_id ~scope_widened );
              ( "claimed_task",
                `Assoc
                  [
                    ("task_id", `String task_id);
                    ("title", `String title);
                    ("priority", `Int priority);
                    ( "released_task_id",
                      Json_util.string_opt_to_json released_task_id );
                  ] );
            ]
      | Workspace.Claim_next_no_eligible _ -> []
      | Workspace.Claim_next_no_unclaimed | Workspace.Claim_next_error _ ->
          []
    in
    let typed_outcome_field =
      match result with
      | Workspace.Claim_next_no_eligible
          { scope_excluded_count
          ; blocked_count
          ; verification_blocked_count
          ; _
          } ->
        Some
          ( "typed_outcome"
          , Keeper_tool_outcome.to_json
              (Keeper_tool_outcome.No_progress
                 { reason =
                     Keeper_tool_outcome.No_eligible_tasks
                       { scope_excluded_count
                       ; blocked_count
                       ; verification_blocked_count
                       }
                 }) )
      | Workspace.Claim_next_no_unclaimed ->
        Some
          ( "typed_outcome"
          , Keeper_tool_outcome.to_json
              (Keeper_tool_outcome.No_progress
                 { reason = Keeper_tool_outcome.No_work_available }) )
      | Workspace.Claim_next_error e ->
        Some
          ( "typed_outcome"
          , Keeper_tool_outcome.to_json
              (Keeper_tool_outcome.Error
                 { reason = Printf.sprintf "keeper_task_claim rejected: %s" e }) )
      | _ -> None
    in
    let payload =
      Yojson.Safe.to_string
        (`Assoc
           ([
              ("result", `String message);
              ("auto_started", `Bool !auto_started_ok);
            ]
             @ (match typed_outcome_field with
                | Some field -> [ field ]
                | None -> [])
           @ claimed_task_fields))
    in
    (match result with
     | Workspace.Claim_next_error _ ->
       Keeper_tool_execution.failure ~class_:Tool_result.Workflow_rejection payload
     | Workspace.Claim_next_claimed _
     | Workspace.Claim_next_no_unclaimed
     | Workspace.Claim_next_no_eligible _ -> Keeper_tool_execution.success payload)
    | Task_done ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let result_text = Safe_ops.json_string ~default:"" "result" args |> String.trim in
    if task_id = ""
    then
      Keeper_tool_execution.failure
        ~class_:Tool_result.Workflow_rejection
        (workflow_rejection_error_json
           ~alternatives:[ "keeper_task_claim"; "keeper_tasks_list" ]
           ~typed_outcome:
             (Keeper_tool_outcome.Error
                { reason = "keeper_task_done rejected: task_id required" })
           "task_id is required. Use the task_id you got from keeper_task_claim.")
    else if result_text = ""
    then
      (* Schema (tool_shard_types.ml:1447) declares [result] as a
         required, minLength:1 field. Other agents verify completion
         from this field, so an empty result hides the audit trail.
         Previously the handler accepted an empty result and either
         (a) silently passed non-strict tasks done with no summary or
         (b) deferred the rejection to parse_handoff_context for
         strict-contract tasks (where keepers received the confusing
         "handoff_context.summary is required" message instead of a
         keeper-vocabulary error). Enforce the schema here so the
         error names the field the keeper actually sent. *)
      Keeper_tool_execution.failure
        ~class_:Tool_result.Workflow_rejection
        (workflow_rejection_error_json
           ~alternatives:[ "keeper_task_done" ]
           ~typed_outcome:
             (Keeper_tool_outcome.Error
                { reason = "keeper_task_done rejected: result required" })
           "result is required. Audit trail: describe what you completed. \
            Example: result='Refactored module X, all tests green, no flake'.")
    else (
      match parse_keeper_task_done_evidence_refs args with
      | Error message ->
        Keeper_tool_execution.failure
          ~class_:Tool_result.Workflow_rejection
          (workflow_rejection_error_json
             ~alternatives:[ "keeper_task_done" ]
             ~typed_outcome:
               (Keeper_tool_outcome.Error
                  { reason = "keeper_task_done rejected: evidence_refs required" })
             message)
      | Ok evidence_refs ->
      (* Map keeper vocabulary (`result`) onto MASC domain typed
         handoff_context.summary so the action=done strict-contract
         path can read the completion summary directly from a typed
         field instead of relying on string-blob siblings. *)
      let args_for_transition =
        [
          "task_id", `String task_id;
          "action", `String "done";
          "notes", `String result_text;
          ( "handoff_context",
            `Assoc
              [ "summary", `String result_text
              ; "evidence_refs", Json_util.json_string_list evidence_refs
              ] );
        ]
      in
      let transition_result =
        Task.Tool.handle_transition
          ~task_list_projection:Tool_capability_projection.Keeper_tasks_list
          ~tool_name:"keeper_task_done"
          ~start_time:0.0
          {
            Task.Tool.config;
            agent_name = keeper_agent_sender ~meta;
            sw = Eio_context.get_switch_opt ();
          }
          (`Assoc args_for_transition)
      in
      let payload =
        keeper_tool_result_json
          ~typed_outcome:
            (if Tool_result.is_success transition_result
             then Some Keeper_tool_outcome.Progress
             else
               (* RFC-0239 / audit D1: a rejected completion (wrong owner, stale
                  or invalid transition) is not progress. Emit a typed Error so the
                  no-progress detector demotes it instead of counting the tool name
                  as evidence. *)
               Some
                 (Keeper_tool_outcome.Error
                    { reason = Tool_result.message transition_result }))
          transition_result
      in
      match transition_result with
      | Ok _ -> Keeper_tool_execution.success payload
      | Error { class_; _ } -> Keeper_tool_execution.failure ~class_ payload)
;;

let handle_keeper_task_tool ~config ~meta ~name ~args =
  (handle_keeper_task_tool_with_outcome ~config ~meta ~name ~args).raw_output
;;
