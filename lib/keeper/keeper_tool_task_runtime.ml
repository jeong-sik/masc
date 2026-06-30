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

let keeper_tool_result_json ?(typed_outcome = (None : Keeper_tool_outcome.t option)) ~failure_class ~(ok : bool) ~(message : string) () =
  let has_json_field name fields =
    List.exists (fun (field, _) -> String.equal field name) fields
  in
  let failure_class_fields =
    match failure_class with
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
  match (ok, Tool_result.structured_payload_of_message message) with
  | false, Some (`Assoc payload_fields) ->
    let payload_fields =
      List.fold_left
        (fun acc (key, value) ->
           if has_json_field key acc then acc else acc @ [ key, value ])
        payload_fields
        (failure_class_fields @ typed_outcome_fields)
    in
    Yojson.Safe.to_string (`Assoc payload_fields)
  | _ ->
    Yojson.Safe.to_string
      (`Assoc
         ([ "ok", `Bool ok
          ; (if ok then "result" else "error"), `String message
          ]
          @ failure_class_fields
          @ typed_outcome_fields))
;;

(* Caller-input validation errors carry [Tool_result.Policy_rejection]. Per
   RFC-0062 §3.2 that variant is "permission, guardrail, validation reject", so
   validation belongs there by original design — and the schema-layer producer
   [Tool_input_validation] already emits Policy_rejection for invalid args.
   Tagging makes the keeper *health* circuit breaker (Gate #1,
   [Keeper_tool_dispatch_runtime.should_apply_circuit_breaker_to_failure_payload])
   exempt these: an LLM that sends malformed/missing args is making an input
   mistake, not exhibiting a keeper-health fault. The per-(tool,args) breaker
   (Gate #2) still counts them, so retrying the SAME bad args stays blocked. *)
let validation_error_json message =
  keeper_tool_result_json
    ~failure_class:(Some Tool_result.Policy_rejection)
    ~ok:false
    ~message
    ()
;;

let validate_goal_id config goal_id =
  match Goal_store.get_goal config ~goal_id with
  | Some _ -> Ok goal_id
  | None -> Error (Printf.sprintf "unknown goal_id: %s" goal_id)
;;

let resolve_task_create_goal_id ~config ~(meta : keeper_meta) args =
  match Safe_ops.json_string_opt "goal_id" args with
  | Some s when String.trim s <> "" ->
      validate_goal_id config (String.trim s) |> Result.map Option.some
  | _ ->
      (match meta.active_goal_ids with
       | [] -> Ok None
       | [ goal_id ] ->
           validate_goal_id config goal_id |> Result.map Option.some
       | _ :: _ :: _ -> Ok None)
;;

(* RFC-0034.v2: per-goal task creation cap moved to
   [Workspace_task_capacity] so all 5 task creation entrypoints share the
   same guard. Pre-RFC-0034.v2, these helpers (and the constant
   [keeper_task_create_goal_open_limit]) lived here as introduced by
   #13981. *)

let active_goal_scope_json
      ~(meta : keeper_meta)
      ?matched_goal_id
      ?excluded_count
      ?blocked_count
      ?verification_blocked_count
      ?scope_excluded_count
      ?explicit_excluded_count
      ?claim_pool_candidate_count
      ?effective_mode
      ?effective_goal_ids
      ?fallback_reason
      ()
  =
  let scoped = meta.active_goal_ids <> [] in
  let mode =
    match effective_mode with
    | Some mode -> mode
    | None -> if scoped then "active_goal_ids" else "all_tasks"
  in
  let effective_goal_ids =
    match effective_goal_ids with
    | Some goal_ids -> goal_ids
    | None -> meta.active_goal_ids
  in
  let fields =
    [
      ("mode", `String mode);
      ("scoped", `Bool scoped);
      ( "active_goal_ids",
        `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids)
      );
      ( "effective_goal_ids",
        `List (List.map (fun goal_id -> `String goal_id) effective_goal_ids)
      );
      ("fallback_reason", Json_util.string_opt_to_json fallback_reason);
      ("matched_goal_id", Json_util.string_opt_to_json matched_goal_id);
    ]
  in
  let fields =
    match excluded_count with
    | Some count -> fields @ [ ("excluded_count", `Int count) ]
    | None -> fields
  in
  let int_fields =
    [ "blocked_count", blocked_count
    ; "verification_blocked_count", verification_blocked_count
    ; "scope_excluded_count", scope_excluded_count
    ; "explicit_excluded_count", explicit_excluded_count
    ; "claim_pool_candidate_count", claim_pool_candidate_count
    ]
    |> List.filter_map (fun (name, value) ->
      Option.map (fun count -> name, `Int count) value)
  in
  let fields = fields @ int_fields in
  `Assoc fields
;;

let claim_scope_context_suffix ~(meta : keeper_meta) claim_goal_scope =
  match claim_goal_scope.Keeper_runtime_contract.mode with
  | "active_goal_ids" ->
    (match meta.active_goal_ids with
     | [] -> " in active goal scope"
     | goal_ids ->
       Printf.sprintf
         " within active_goal_ids=[%s]"
         (String.concat ", " goal_ids))
  | "all_tasks" -> " across all tasks"
  | "empty_goal_scope_fallback_all_tasks" ->
    " after active-goal fallback to all tasks"
  | mode -> Printf.sprintf " in claim_scope.mode=%s" mode
;;

let no_eligible_action_for_claim_scope claim_goal_scope ~excluded_count =
  match claim_goal_scope.Keeper_runtime_contract.fallback_reason with
  | Some _ ->
    Printf.sprintf
      "ACTION: Stop scope-lock diagnosis; claim_scope.mode=%s already searched all \
       tasks; resolve blockers/excluded=%d."
      claim_goal_scope.Keeper_runtime_contract.mode
      excluded_count
  | None ->
    let scope_hint =
      match claim_goal_scope.Keeper_runtime_contract.mode with
      | "active_goal_ids" ->
        (* Scope only stays in [active_goal_ids] mode when a Todo task IS linked
           to the goal (otherwise the resolver falls back to all_tasks). So a
           no-eligible here means those scoped tasks exist but are blocked /
           awaiting verification — not a scope lock to clear. *)
        " Scoped tasks exist but are blocked or awaiting verification; resolve those blockers."
      | _ -> ""
    in
    Printf.sprintf
      "ACTION: Stop task-checking — blocked/excluded=%d.%s"
      excluded_count
      scope_hint
;;

let no_eligible_blocker_summary
      ~blocked_count
      ~verification_blocked_count
      ~scope_excluded_count
  =
  Printf.sprintf
    "Diagnostics: goal_scope_or_filter=%d, verification=%d, blocked=%d."
    scope_excluded_count
    verification_blocked_count
    blocked_count
;;


let wip_admission_kind = "claim_wip_admission"

let wip_admission_action =
  "finish_or_release_existing_wip_before_claiming_more"
;;

let wip_admission_scope_note =
  "This is a WIP claim-admission cap, not a request to create a new repo; do not create unrelated repos to bypass it."
;;

let wip_admission_rejection_json
      (task_id, (rejection : Keeper_wip_admission.rejection))
  =
  `Assoc
    [ "task_id", `String task_id
    ; "reason", `String (Keeper_wip_admission.reject_reason_to_string rejection.reason)
    ; "axis", `String (Keeper_wip_admission.reject_reason_axis rejection.reason)
    ; "cap_kind", `String "wip_claim_admission"
    ; "action", `String wip_admission_action
    ; "scope_note", `String wip_admission_scope_note
    ; "current", `Int rejection.current
    ; "limit", `Int rejection.limit
    ; "scope_key", `String rejection.scope_key
    ]
;;

let wip_admission_rejection_action = function
  | [] -> None
  | (task_id, (rejection : Keeper_wip_admission.rejection)) :: _ ->
    Some
      (Printf.sprintf
         "WIP admission rejected task %s: %s current=%d limit=%d scope=%s. ACTION: finish/release existing WIP in this scope before claiming more. %s"
         task_id
         (Keeper_wip_admission.reject_reason_to_string rejection.reason)
         rejection.current
         rejection.limit
         rejection.scope_key
         wip_admission_scope_note)
;;

let wip_admission_result_fields rejections =
  match rejections with
  | [] -> []
  | rejections ->
    [ ( "wip_admission"
      , `Assoc
          [ "kind", `String wip_admission_kind
          ; "action", `String wip_admission_action
          ; "rejected_count", `Int (List.length rejections)
          ; "rejections", `List (List.map wip_admission_rejection_json rejections)
          ] )
    ]
;;

let find_task_goal_id config task_id =
  let index = Workspace_goal_index.build_task_goal_index_for_config config in
  try Some (List.hd (Hashtbl.find index task_id)) with Not_found -> None
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

let handle_keeper_task_tool
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match task_op_of_name name with
  | None -> error_json ~fields:[ "tool", `String name ] "unknown_task_tool"
  | Some op ->
    match op with
    | Tasks_list ->
    let status_filter = Safe_ops.json_string_opt "status" args in
    let include_done = Safe_ops.json_bool ~default:false "include_done" args in
    let limit = Safe_ops.json_int ~default:50 "limit" args |> max 1 |> min 100 in
    let result = Workspace.list_tasks ?status:status_filter ~include_done config in
    (match Yojson.Safe.from_string result with
     | `List items ->
       Yojson.Safe.to_string (`List (List.filteri (fun i _ -> i < limit) items))
     | _ -> result
     | exception Yojson.Json_error _ ->
       let lines = String.split_on_char '\n' result in
       String.concat "\n" (List.filteri (fun i _ -> i < limit + 2) lines))
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
    Yojson.Safe.to_string
      (`Assoc
         [ "orphan_count", `Int (List.length orphans)
         ; "orphans", `List items
         ; "action", `String action_hint
         ; ( "typed_outcome"
           , Keeper_tool_outcome.to_json
               (if orphans = []
                then Keeper_tool_outcome.No_progress { reason = No_work_available }
                else Keeper_tool_outcome.Progress) )
         ])
    | Broadcast ->
    let message = Safe_ops.json_string ~default:"" "message" args |> String.trim in
    if message = ""
    then error_json "message is required. Good: message='Build complete, all tests pass.'."
    else (
      let _ =
        Workspace.broadcast config ~from_agent:(keeper_agent_sender ~meta) ~content:message
      in
      Yojson.Safe.to_string
        (`Assoc
           [ "ok", `Bool true
           ; "broadcast", `String message
           ; "typed_outcome", Keeper_tool_outcome.to_json Keeper_tool_outcome.Progress
           ]))
    | Task_create ->
    let title = Safe_ops.json_string ~default:"" "title" args |> String.trim in
    let description = Safe_ops.json_string ~default:"" "description" args |> String.trim in
    let priority = Safe_ops.json_int ~default:3 "priority" args |> max 1 |> min 5 in
    if title = ""
    then validation_error_json "title is required. Provide a clear, actionable task title."
    else if description = ""
    then
      validation_error_json
        "description is required. Explain what needs to be done and why."
    else (
      match resolve_task_create_goal_id ~config ~meta args with
      | Error message -> validation_error_json message
      | Ok goal_id ->
          (* De-duplicated: this keeper-internal path now shares the canonical
             [Task.Args.parse_task_contract] used by the public
             masc_task_create facade. The previous local copy
             [parse_task_contract_arg] had regressed — it rejected an OMITTED
             optional [contract] via a catch-all that conflated None(omitted)
             with a wrong-typed value, which falsely failed keeper_task_create
             and tripped the keeper failure circuit breaker. Same lib, no
             dependency wall; the canonical parser handles [None | Some `Null]. *)
          (match Task.Args.parse_task_contract args with
           | Error message -> validation_error_json message
           | Ok contract ->
              let capacity_error =
                let backlog = Workspace.read_backlog config in
                Workspace_task_capacity.check_for_config config ?goal_id backlog
              in
              (match capacity_error with
               | Some error -> Workspace_task_capacity.error_to_json_string error
               | None ->
              let result =
                Workspace_task.add_task
                  ?contract
                  ?goal_id
                  ~reject_if:
                    (Workspace_task_capacity.rejection_for_add_task_for_config
                       config
                       ?goal_id)
                  config
                  ~title
                  ~priority
                  ~description
              in
              Yojson.Safe.to_string
                (`Assoc
                  [
                    "ok", `Bool true;
                    "result", `String result;
                    "goal_id", Json_util.string_opt_to_json goal_id;
                    ( "typed_outcome"
                    , Keeper_tool_outcome.to_json Keeper_tool_outcome.Progress );
                  ]))))
    | Task_claim ->
    let claim_goal_scope =
      Keeper_runtime_contract.resolve_claim_goal_scope ~config ~meta ()
    in
    let wip_rejections = ref [] in
    let task_goal_index = Workspace_goal_index.build_task_goal_index_for_config config in
    let remember_wip_rejection task_id rejection =
      if not (List.exists (fun (existing_id, _) -> String.equal existing_id task_id) !wip_rejections)
      then wip_rejections := (task_id, rejection) :: !wip_rejections
    in
    let wip_admission_filter ~active_tasks task =
      let active_items =
        Keeper_wip_admission.active_items_of_tasks ~task_goal_index active_tasks
      in
      let scope =
        Keeper_wip_admission.scope_of_task ~task_goal_index task
      in
      match Keeper_wip_admission.decide active_items ~scope with
      | Keeper_wip_admission.Admit _ -> true
      | Keeper_wip_admission.Reject rejection ->
        remember_wip_rejection task.id rejection;
        false
    in
    let requested_task_id =
      Safe_ops.json_string ~default:"" "task_id" args |> String.trim
    in
    let explicit_claim_result () =
      let tasks = Workspace.get_tasks_raw config in
      let claim_specific task =
        let active_tasks =
          List.filter
            (fun (active : Masc_domain.task) ->
               not (String.equal active.id requested_task_id))
            tasks
        in
        if not (wip_admission_filter ~active_tasks task)
        then
          Workspace.Claim_next_no_eligible
            { excluded_count = 1
            ; blocked_count = 0
            ; verification_blocked_count = 0
            ; scope_excluded_count = 0
            ; explicit_excluded_count = 1
            ; claim_pool_candidate_count = 1
            }
        else (
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
          | Error e -> Workspace.Claim_next_error (Masc_domain.masc_error_to_string e))
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
    let result =
      if requested_task_id <> "" then
        explicit_claim_result ()
      else
        Workspace.claim_next_r config ~agent_name:meta.agent_name
          ~task_filter:claim_goal_scope.task_filter
          ~admission_filter:wip_admission_filter
          ~allow_scope_fallback:true
          ()
    in
    let wip_rejections = List.rev !wip_rejections in
    let auto_started_ok = ref false in
    let harness_completed = ref false in
    (match result with
     | Workspace.Claim_next_claimed { task_id; scope_widened; _ } ->
       sync_keeper_meta_current_task ~config ~meta ~task_id;
       (* Make the scope override visible: this is a claim outside the keeper's
          active_goal_ids, taken because no in-scope task was admission-eligible
          (schedule-level fallback). Silent widening would let operators misread
          the keeper's scope. *)
       if scope_widened then
         Log.Keeper.info ~keeper_name:meta.name
           "goal-scope widened to all_tasks for claim of %s: no in-scope task was \
            admission-eligible (active_goal_ids=[%s])"
           task_id
           (String.concat ", " meta.active_goal_ids);
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
             ~tool_name:"keeper_auto_start"
             ~start_time:0.0
             { Task.Tool.config; agent_name = keeper_agent_sender ~meta;
               sw = Eio_context.get_switch_opt () }
             (`Assoc ["task_id", `String task_id; "action", `String "start"])
         in
         auto_started_ok := Tool_result.is_success start_result
       end else
         auto_started_ok := true;
       (* RFC-0199 Phase B: deterministic evidence harness. When the claimed
          task declares typed [evidence_claims] and all are satisfied by a file
          probe, complete it immediately — no LLM turn. Uses [force_done_task_r]
          so a deterministic check does not route through the non-deterministic
          anti-rationalization gate (force_done is the existing keeper-Done
          path; Done_action is exempt from the legacy substring gate). Guarded to
          Claimed/InProgress so it never hits the AwaitingVerification
          Invalid_transition; idempotent if another agent reached Done first. *)
       (match
          Workspace.get_tasks_raw config
          |> List.find_opt (fun (t : Masc_domain.task) ->
                 String.equal t.id task_id)
        with
        | Some
            { contract = Some { evidence_claims = _ :: _ as claims; _ }
            ; task_status = (Masc_domain.Claimed _ | Masc_domain.InProgress _)
            ; _
            }
          when Keeper_deterministic_evidence_probe.all_satisfied ~config ~meta
                 claims ->
          let summary =
            claims
            |> List.map Evidence_claim.to_human_string
            |> String.concat "; "
          in
          let notes =
            Printf.sprintf
              "RFC-0199 deterministic harness: %d evidence claim(s) satisfied \
               [%s]"
              (List.length claims) summary
          in
          (match
             Workspace.force_done_task_r config
               ~agent_name:(keeper_agent_sender ~meta) ~task_id ~notes ()
           with
           | Ok _ -> harness_completed := true
           | Error _ -> ())
        | _ -> ())
     | Workspace.Claim_next_no_unclaimed
     | Workspace.Claim_next_no_eligible _
     | Workspace.Claim_next_error _ -> ());
    let accountability_warning =
      if
        Keeper_accountability.accountability_risk_is_high config
          ~keeper_name:meta.name ~agent_name:meta.agent_name
      then
        Some
          "Accountability risk is high for this keeper. Prefer manual review or lower-risk routing when equivalent."
      else
        None
    in
    let message =
      match result with
      | Workspace.Claim_next_claimed { message; _ } ->
          if !harness_completed then
            message
            ^ " Task completed immediately — all declared evidence claims were \
               already satisfied (no work needed)."
          else if !auto_started_ok then
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
        let action =
          match wip_admission_rejection_action wip_rejections with
          | Some rejection -> rejection
          | None ->
            no_eligible_action_for_claim_scope claim_goal_scope ~excluded_count
        in
        Printf.sprintf
          "No eligible tasks%s. %s %s"
          (claim_scope_context_suffix ~meta claim_goal_scope)
          action
          (no_eligible_blocker_summary
             ~blocked_count
             ~verification_blocked_count
             ~scope_excluded_count)
      | Workspace.Claim_next_error e -> Printf.sprintf "Error: %s" e
    in
    let claim_scope, claimed_task_fields =
      match result with
      | Workspace.Claim_next_claimed
          { task_id; title; priority; released_task_id; scope_widened; _ } ->
          let matched_goal_id = find_task_goal_id config task_id in
          ( active_goal_scope_json ~meta ?matched_goal_id
              ~effective_mode:claim_goal_scope.mode
              ~effective_goal_ids:claim_goal_scope.effective_goal_ids
              ?fallback_reason:claim_goal_scope.fallback_reason ()
          , [
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
                    ( "goal_id",
                      Json_util.string_opt_to_json matched_goal_id );
                    ( "released_task_id",
                      Json_util.string_opt_to_json released_task_id );
                  ] );
            ] )
      | Workspace.Claim_next_no_eligible
          { excluded_count
          ; blocked_count
          ; verification_blocked_count
          ; scope_excluded_count
          ; explicit_excluded_count
          ; claim_pool_candidate_count
          } ->
          ( active_goal_scope_json
              ~meta
              ~excluded_count
              ~blocked_count
              ~verification_blocked_count
              ~scope_excluded_count
              ~explicit_excluded_count
              ~claim_pool_candidate_count
              ~effective_mode:claim_goal_scope.mode
              ~effective_goal_ids:claim_goal_scope.effective_goal_ids
              ?fallback_reason:claim_goal_scope.fallback_reason ()
          , [] )
      | Workspace.Claim_next_no_unclaimed | Workspace.Claim_next_error _ ->
          ( active_goal_scope_json ~meta ~effective_mode:claim_goal_scope.mode
              ~effective_goal_ids:claim_goal_scope.effective_goal_ids
              ?fallback_reason:claim_goal_scope.fallback_reason ()
          , [] )
    in
    let typed_outcome_field =
      match result with
      | Workspace.Claim_next_no_eligible
          { scope_excluded_count
          ; blocked_count
          ; verification_blocked_count
          ; _
          } ->
        let all_goals_excluded =
          match claim_goal_scope.effective_goal_ids with
          | [] -> true
          | _ -> false
        in
        Some
          ( "typed_outcome"
          , Keeper_tool_outcome.to_json
              (Keeper_tool_outcome.No_progress
                 { reason =
                     Keeper_tool_outcome.No_eligible_tasks
                       { scope_excluded_count
                       ; blocked_count
                       ; verification_blocked_count
                       ; all_goals_excluded
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
    Yojson.Safe.to_string
      (`Assoc
         ([
            ("result", `String message);
            ("claim_scope", claim_scope);
            ("auto_started", `Bool !auto_started_ok);
          ]
         @ (match typed_outcome_field with
            | Some field -> [ field ]
            | None -> [])
         @ claimed_task_fields
         @ wip_admission_result_fields wip_rejections
         @
         match accountability_warning with
         | Some warning -> [ ("routing_warning", `String warning) ]
         | None -> []))
    | Task_done ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let result_text = Safe_ops.json_string ~default:"" "result" args |> String.trim in
    if task_id = ""
    then
      workflow_rejection_error_json
        ~alternatives:[ "keeper_task_claim"; "keeper_tasks_list" ]
        ~typed_outcome:
          (Keeper_tool_outcome.Error
             { reason = "keeper_task_done rejected: task_id required" })
        "task_id is required. Use the task_id you got from keeper_task_claim."
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
      workflow_rejection_error_json
        ~alternatives:[ "keeper_task_done" ]
        ~typed_outcome:
          (Keeper_tool_outcome.Error
             { reason = "keeper_task_done rejected: result required" })
        "result is required. Audit trail: describe what you completed. \
         Example: result='Refactored module X, all tests green, no flake'."
    else (
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
            `Assoc [ "summary", `String result_text ] );
        ]
      in
      let transition_result =
        Task.Tool.handle_transition
          ~tool_name:"keeper_task_done"
          ~start_time:0.0
          {
            Task.Tool.config;
            agent_name = keeper_agent_sender ~meta;
            sw = Eio_context.get_switch_opt ();
          }
          (`Assoc args_for_transition)
      in
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
        ~failure_class:(Tool_result.failure_class transition_result)
        ~ok:(Tool_result.is_success transition_result)
        ~message:(Tool_result.message transition_result)
        ())
;;
