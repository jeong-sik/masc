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
        | Masc_domain.Claimed { claimed_at; _ } ->
            Masc_domain.parse_iso8601 ~default_time:(Time_compat.now () -. 60.0) claimed_at
        | _ -> Time_compat.now () -. 60.0)
    | None -> Time_compat.now () -. 60.0
  in
  let result = Workspace.cancel_task_r ctx.config ~agent_name:ctx.agent_name ~task_id ~reason in
  (* Record failed metric on cancellation *)
  (match result with
   | Ok _ ->
       sync_owner_current_task_binding ctx;
       sync_planning_current_task_with_owned_task ctx;
       (Atomic.get Workspace_hooks.record_task_metric_fn)
         ctx.config
         ~agent_id:ctx.agent_name
         ~task_id
         ~started_at:started_at_actual
         ~completed_at:(Some (Time_compat.now ()))
         ~success:false
         ~error_message:(Some (if String.equal reason "" then "Cancelled" else reason))
         ~collaborators:[]
         ~handoff_from:None
         ~handoff_to:None;
       (* Feed failure into Thompson Sampling quality signal *)
       (Atomic.get Workspace_hooks.record_thompson_result_fn)
         ~agent_name:ctx.agent_name
         ~success:false
         ~reason:(Some "task_cancelled");
       (* Notification harness: push cancel event to all active sessions *)
       (Atomic.get Workspace_hooks.push_task_event_fn)
         ~event_type:"masc/task_cancelled"
         ~details:[
           ("task_id", `String task_id);
           ("agent_name", `String ctx.agent_name);
           ("reason", `String reason);
         ]
   | Error err ->
       task_log_error ~task_id "metrics record failed: %s" (Masc_domain.masc_error_to_string err));
  result_to_response ~tool_name ~start_time result

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
      ~failure_class:(Some Tool_result.Workflow_rejection)
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
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      (Printf.sprintf "action is required (%s)" (String.concat ", " Masc_domain.valid_task_action_strings))
  else
  match Masc_domain.task_action_of_string action_raw with
  | Error msg ->
      (* RFC-0189: caller passed an unknown action enum value. *)
      Tool_result.error
        ~failure_class:(Some Tool_result.Workflow_rejection)
        ~tool_name ~start_time msg
  | Ok action ->
  let requested_action = action in
  let action_s = Masc_domain.task_action_to_string action in
  let transition_action_denylist = owner_transition_action_denylist ctx in
  if
    transition_action_denied_by_denylist
      ~tool_denylist:transition_action_denylist
      ~action:action_s
  then
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name
      ~start_time
      (transition_action_policy_rejection
         ~agent_name:ctx.agent_name
         ~action:action_s
         ~allowed_actions:
           (transition_action_allowed_actions
              ~tool_denylist:transition_action_denylist))
  else
  let notes = get_string args "notes" "" in
  let reason = get_string args "reason" "" in
  let completion_contract =
    match get_string_list args "completion_contract" with
    | [] -> None
    | items -> Some items
  in
  let evaluator_runtime = get_string_opt args "evaluator_runtime" in
  let handoff_context =
    parse_handoff_context ~agent_name:ctx.agent_name ~action args
  in
  let expected_version = get_int_opt args "expected_version" in
  let force_raw = get_bool args "force" false in
  (* force=true requires admin privilege: initial_admin or Admin role *)
  let force =
    if force_raw then
      if (Atomic.get Workspace_hooks.is_admin_agent_fn) ~base_path:ctx.config.base_path ~agent_name:ctx.agent_name then true
      else (
        task_log_warn ~task_id "[anti-rationalization] force=true rejected: agent=%s lacks admin privilege"
          ctx.agent_name;
        false
      )
    else false
  in
  let tasks = Workspace.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks in
  match task_opt with
  | None ->
    missing_live_task_transition_rejection ~tool_name ~start_time ctx ~task_id ~action_s
  | Some _ ->
  let release_owner_mismatch_rejection =
    match action, task_opt with
    | Masc_domain.Release, Some task ->
      (match Workspace.task_assignee_of_status task.task_status with
       | Some assignee
         when (not force)
              && not (Workspace.same_task_actor ctx.config assignee ctx.agent_name) ->
         let status = Masc_domain.task_status_to_string task.task_status in
         let message =
           Printf.sprintf
             "Task %s is %s and owned by %s; %s cannot release it. Use \
              keeper_board_post or masc_board_post to ask the current assignee \
              for handoff/release, or claim different unowned work."
             task_id
             status
             assignee
             ctx.agent_name
         in
         Some
           (Tool_result.error
              ~failure_class:(Some Tool_result.Workflow_rejection)
              ~tool_name
              ~start_time
              (workflow_rejection_payload_json
                 ~rule_id:"task_release_requires_current_owner"
                 ~tool_suggestion:"keeper_board_post"
                 ~hint:
                   "Do not retry masc_transition(action=release) for a task owned \
                    by another keeper. Ask the current assignee for handoff/release \
                    on the board, or inspect and claim different unowned work."
                 ~scope_policy:"observe"
                 ~alternatives:
                   [ "keeper_board_post"; "masc_board_post"; "keeper_tasks_list"; "keeper_task_claim" ]
                 ~extra_fields:
                   [ "task_id", `String task_id
                   ; "task_status", `String status
                   ; "current_assignee", `String assignee
                   ; "requested_agent", `String ctx.agent_name
                   ]
                 message))
       | Some _ | None -> None)
    | Masc_domain.Release, None -> None
    | ( Masc_domain.Claim
      | Masc_domain.Start
      | Masc_domain.Done_action
      | Masc_domain.Cancel
      | Masc_domain.Submit_for_verification
      | Masc_domain.Approve_verification
      | Masc_domain.Reject_verification
      | Masc_domain.Mark_operator_blocked
      | Masc_domain.Unblock ), _ -> None
  in
  match release_owner_mismatch_rejection with
  | Some result -> result
  | None ->
  let terminal_verdict_noop =
    if transition_action_policy_applies transition_action_denylist
       && is_verdict_transition_action action
    then
      match task_opt with
      | Some task when Masc_domain.task_status_is_terminal task.task_status ->
        Some
          (terminal_verdict_noop_message
             ~task_id
             ~action:action_s
             ~status:(Masc_domain.task_status_to_string task.task_status))
      | _ -> None
    else
      None
  in
  match terminal_verdict_noop with
  | Some message -> Tool_result.ok ~tool_name ~start_time message
  | None ->
  let completion_state_error =
    if (=) action Masc_domain.Done_action && not force then
      completion_state_error ~task_id ~agent_name:ctx.agent_name ~task_opt
    else
      None
  in
  match completion_state_error with
  | Some err ->
    log_task_transition_failed ~agent_name:ctx.agent_name err;
    let message = Masc_domain.masc_error_to_string err in
    let rule_id, tool_suggestion, hint, alternatives =
      match err with
      | Masc_domain.Task (Masc_domain.Task_error.NotClaimed _) ->
        ( Some "task_done_requires_claimed_or_started"
        , Some "masc_transition"
        , Some
            "The task is still todo. Use masc_transition with action=claim for \
             this task_id, then action=start, and call keeper_task_done only \
             after the deliverable is complete."
        , [ "masc_transition"; "keeper_task_claim"; "keeper_tasks_list" ] )
      | Masc_domain.Task (Masc_domain.Task_error.AlreadyClaimed _) ->
        ( Some "task_done_requires_current_owner"
        , Some "keeper_tasks_list"
        , Some
            "Another agent owns this task. Inspect the task list, ask for handoff, \
             or claim different unowned work instead of retrying keeper_task_done."
        , [ "keeper_tasks_list"; "keeper_board_post"; "keeper_task_claim" ] )
      | Masc_domain.Task (Masc_domain.Task_error.InvalidState _) ->
        ( Some "task_done_invalid_lifecycle_state"
        , Some "keeper_tasks_list"
        , Some
            "The task lifecycle state does not accept keeper_task_done. Inspect \
             task status and use the valid next lifecycle action."
        , [ "keeper_tasks_list"; "masc_transition" ] )
      | _ ->
        ( Some "task_done_lifecycle_rejected"
        , Some "keeper_tasks_list"
        , Some "Inspect the task status before trying another lifecycle action."
        , [ "keeper_tasks_list"; "masc_transition" ] )
    in
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name
      ~start_time
      (workflow_rejection_payload_json
         ?rule_id
         ?tool_suggestion
         ?hint
         ?recoverable:
           (match rule_id with
            | Some "task_done_requires_claimed_or_started" -> Some true
            | _ -> None)
         ~scope_policy:"observe"
         ~alternatives
         message)
  | None ->
  match client_side_transition_gate_error ~task_opt ~action ~action_s with
  | Some (Masc_domain.Task_error.InvalidState message as err) ->
    log_task_transition_failed ~agent_name:ctx.agent_name (Masc_domain.Task err);
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name
      ~start_time
      (workflow_rejection_payload_json
         ~rule_id:"task_transition_invalid_state"
         ~tool_suggestion:"keeper_tasks_list"
         ~hint:
           "The requested lifecycle transition is not valid for the task's current \
            state. Inspect the task status and use a valid next action instead of \
            retrying the same transition."
         ~scope_policy:"observe"
         ~recoverable:false
         ~alternatives:[ "keeper_tasks_list"; "masc_tasks"; "masc_transition" ]
         ~extra_fields:
           [ "task_id", `String task_id
           ; "action", `String action_s
           ; "requested_agent", `String ctx.agent_name
           ]
         (Printf.sprintf "Invalid task state: %s" message))
  | Some err ->
    log_task_transition_failed ~agent_name:ctx.agent_name (Masc_domain.Task err);
    result_to_response ~tool_name ~start_time (Error (Masc_domain.Task err))
  | None ->
  match handoff_context with
  | Error error ->
      (* RFC-0189: handoff_context parse error — caller passed
         malformed payload. *)
      Tool_result.error
        ~failure_class:(Some Tool_result.Workflow_rejection)
        ~tool_name ~start_time error
  | Ok handoff_context ->
  if (=) action Masc_domain.Release && strict_release_requires_handoff task_opt
     && Option.is_none handoff_context
  then
    (* RFC-0189: strict-release-without-handoff = workflow violation. *)
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      "Strict task release requires handoff_context.summary"
  else
  let completion_owned_by_caller =
    force || can_review_completion ~task_opt ~agent_name:ctx.agent_name
  in
  let persisted_gate_rejection =
    if (=) action Masc_domain.Done_action && not force then
      if not completion_owned_by_caller then
        None
      else if task_has_persisted_contract task_opt then
        persisted_contract_rejection ~ctx ~task_opt ~notes
      else
        None
    else
      None
  in
  match persisted_gate_rejection with
  | Some reason ->
    (* RFC-0189: persisted-contract gate rejected the completion
       attempt — operator-supplied notes don't satisfy the
       contract. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time reason
  | None ->
  let evidence_refs =
        match handoff_context with
        | Some h -> h.evidence_refs
        | None -> []
      in
      let review_gate_rejection =
    if (=) action Masc_domain.Done_action && not force then
      if not completion_owned_by_caller then
        None
      else if can_review_completion ~task_opt ~agent_name:ctx.agent_name then
        review_completion_notes
          ~completion_contract:
            (match persisted_completion_contract ~task_opt with
             | Some persisted -> Some persisted
             | None -> completion_contract)
          ~evaluator_runtime
          ~operator_override:false
          ~ctx
          ~task_opt
          ~task_id
          ~notes
          ~evidence_refs
      else
        None
    else
      None
  in
  match review_gate_rejection with
  | Some reason ->
    (* RFC-0189: review gate rejected the completion attempt — the
       Cdal evaluator runtime returned an actionable verdict the
       caller can address. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time
      (completion_rejection_message ~allow_force:true reason)
  | None ->
  (* Contracted Done actions are reviewed above by the LLM completion
     reviewer with the persisted completion contract in prompt context.
     Keep AwaitingVerification for explicit submit_for_verification only; a
     normal done action must not depend on the verifier agent being alive. *)
  (* RFC-0109 Phase D hard cut: contracted verification submissions
     require substantive evidence. Analysis-only tasks (no contract)
     bypass the gate. *)
  (* Evidence gate is NOT bypassed by force=true. This is intentional:
     force bypasses business-logic guards, but the evidence gate is a safety
     invariant that prevents silent task_done without a substantiveness check.
     Even operator-forced completions should produce auditable evidence. *)
  let evidence_decision =
    let needs_gate =
      match requested_action with
      | Masc_domain.Submit_for_verification
      | Masc_domain.Done_action -> true
      | Masc_domain.Claim
      | Masc_domain.Start
      | Masc_domain.Cancel
      | Masc_domain.Release
      | Masc_domain.Approve_verification
      | Masc_domain.Reject_verification
      | Masc_domain.Mark_operator_blocked
      | Masc_domain.Unblock ->
        false
    in
    if not needs_gate then Workspace_hooks.Pass
    else
      (Atomic.get Workspace_hooks.task_completion_gate_decide_fn)
        ~base_path:ctx.config.base_path
        ~task_id
        ~task_opt
        ~notes
        ~handoff:handoff_context
        ()
  in
  match evidence_decision with
  | Workspace_hooks.Reject { reason; rule_id; hint; payload_json } ->
    let extra_fields =
      match payload_json with
      | `Null -> []
      | other -> [ "cdal_verdict_payload", other ]
    in
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name
      ~start_time
      (workflow_rejection_payload_json
         ~rule_id
         ~hint
         ~scope_policy:"observe"
         ~extra_fields
         reason)
  | Workspace_hooks.Pass ->
  let action_s = Masc_domain.task_action_to_string action in
  let default_time = Time_compat.now () -. 60.0 in
  let (started_at_actual, collaborators_from_task) = match task_opt with
    | Some t -> (match t.task_status with
        | Masc_domain.InProgress { started_at; assignee } ->
            let ts = Masc_domain.parse_iso8601 ~default_time started_at in
            let collabs = if not (String.equal assignee "") && not (String.equal assignee ctx.agent_name) then [assignee] else [] in
            (ts, collabs)
        | Masc_domain.Claimed { claimed_at; assignee } ->
            let ts = Masc_domain.parse_iso8601 ~default_time claimed_at in
            let collabs = if not (String.equal assignee "") && not (String.equal assignee ctx.agent_name) then [assignee] else [] in
            (ts, collabs)
        | _ -> (default_time, []))
    | None -> (default_time, [])
  in
  let max_cas_retries = 3 in
  let cas_retry_delay_s = 0.05 in
  let version_mismatch_prefix = "Version mismatch" in
  (* TODO(task-cas): replace this string bridge with a typed
     [Task_error.Version_mismatch] variant.  Today [transition_task_r] emits
     this prefix only for caller-supplied [expected_version=Some _] guards, so
     the retry below is intentionally gated to [expected_version=None]; a stale
     explicit CAS guard must fail instead of becoming a blind retry. *)
  let is_version_mismatch = function
    | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState msg)) ->
        String.length msg >= String.length version_mismatch_prefix
        && String.equal
             (Stdlib.String.sub msg 0 (String.length version_mismatch_prefix))
             version_mismatch_prefix
    | _ -> false
  in
  let prepare_verification_request =
    match action with
    | Masc_domain.Submit_for_verification ->
      Some
        (fun ~task ~assignee ~verification_id ~evidence_refs ->
           (Atomic.get Workspace_hooks.verification_submit_request_fn)
             ctx.config
             ~task
             ~assignee
             ~verification_id
             ~evidence_refs)
    | Masc_domain.Claim
    | Masc_domain.Start
    | Masc_domain.Done_action
    | Masc_domain.Cancel
    | Masc_domain.Release
    | Masc_domain.Approve_verification
    | Masc_domain.Reject_verification
    | Masc_domain.Mark_operator_blocked
    | Masc_domain.Unblock ->
      None
  in
  (* RFC-0221 §3.1: compensation for [Submit_for_verification]. If the status
     commit fails after [prepare_verification_request] wrote the record,
     [transition_task_r] calls this to delete the orphaned record so the two
     stores never disagree. Best-effort: a failure is logged, not propagated —
     the transition is already failing on its own error. *)
  let compensate_verification_request =
    match action with
    | Masc_domain.Submit_for_verification ->
      Some
        (fun ~verification_id ->
           match
             (Atomic.get Workspace_hooks.verification_delete_request_fn)
               ctx.config
               ~verification_id
           with
           | Ok () -> ()
           | Error e ->
             task_log_warn
               ~task_id
               "[RFC-0221] compensation delete_request failed (vrf=%s): %s"
               verification_id
               e)
    | Masc_domain.Claim
    | Masc_domain.Start
    | Masc_domain.Done_action
    | Masc_domain.Cancel
    | Masc_domain.Release
    | Masc_domain.Approve_verification
    | Masc_domain.Reject_verification
    | Masc_domain.Mark_operator_blocked
    | Masc_domain.Unblock ->
      None
  in
  let prepare_verification_verdict =
    match action with
    | Masc_domain.Approve_verification
    | Masc_domain.Reject_verification ->
      Some
        (fun ~(task : Masc_domain.task) ~verifier ~verification_id ~decision ->
           match decision with
           | `Approve notes ->
             (Atomic.get Workspace_hooks.verification_record_verdict_fn)
               ctx.config
               ~task_id:task.id
               ~verifier
               ~verification_id
               ~decision:(`Approve notes)
           | `Reject reason ->
             (Atomic.get Workspace_hooks.verification_record_verdict_fn)
               ctx.config
               ~task_id:task.id
               ~verifier
               ~verification_id
               ~decision:(`Reject reason))
    | Masc_domain.Claim
    | Masc_domain.Start
    | Masc_domain.Done_action
    | Masc_domain.Cancel
    | Masc_domain.Release
    | Masc_domain.Submit_for_verification
    | Masc_domain.Mark_operator_blocked
    | Masc_domain.Unblock ->
      None
  in
  let verifier_approve_gate_rejection =
    if (=) action Masc_domain.Approve_verification
       && task_has_strict_persisted_contract task_opt
    then
      persisted_contract_rejection ~ctx ~task_opt ~notes
    else
      None
  in
  match verifier_approve_gate_rejection with
  | Some reason ->
    (* RFC-0189: verifier-approval gate rejected the transition —
       caller (verifier) tried to approve without satisfying the
       persisted contract. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name ~start_time reason
  | None ->
  let rec try_transition attempt =
      let r = Workspace.transition_task_r ctx.config ~agent_name:ctx.agent_name
                ~task_id ~action ?expected_version ~notes ~reason
                (* RFC-0262: the admin-gated [force] bool (l.164, already
                   verified against initial_admin) maps to Operator authority;
                   a non-admin or no-force caller acts as Assignee. *)
                ~authority:(if force then Masc_domain.Operator else Masc_domain.Assignee)
                ?handoff_context ?prepare_verification_request
                ?compensate_verification_request
                ?prepare_verification_verdict () in
      if
        is_version_mismatch r
        && Option.is_none expected_version
        && attempt < max_cas_retries
      then begin
        task_log_info ~task_id "CAS version mismatch on %s (attempt %d/%d), retrying in %.0fms"
          task_id (attempt + 1) max_cas_retries (cas_retry_delay_s *. 1000.0);
        try
          Time_compat.sleep cas_retry_delay_s;
          try_transition (attempt + 1)
        with Failure msg when String.starts_with ~prefix:"Time_compat.sleep:" msg ->
          r
      end else
        r
  in
  (* Capture verification_id from AwaitingVerification state BEFORE transition.
     approve/reject transitions change state, destroying the verification_id.
     Issue #7543. *)
  let verification_id_before =
    match task_opt with
    | Some t -> (match t.task_status with
        | Masc_domain.AwaitingVerification { verification_id; _ } -> Some verification_id
        | _ -> None)
    | None -> None
  in
  let result = try_transition 0 in
  (match result with
   | Ok _ ->
     sync_owner_current_task_binding ctx;
     sync_planning_current_task_with_owned_task ctx
   | Error _ -> ());
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
       (match action with
        | Masc_domain.Submit_for_verification ->
          let tasks = Workspace.get_tasks_raw ctx.config in
          (match List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks with
           | Some task ->
             let evidence_refs = verification_evidence_refs_for_task task in
             (match task.task_status with
             | Masc_domain.AwaitingVerification { verification_id; assignee; _ } ->
                (Atomic.get Workspace_hooks.verification_notify_submit_fn)
                  ctx.config ~task ~assignee ~verification_id ~evidence_refs
              | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
              | Masc_domain.Done _ | Masc_domain.Cancelled _ | Masc_domain.Operator_blocked _ -> ())
           | None -> ())
        | Masc_domain.Approve_verification ->
          (* Previously this arm used [Option.value ~default:""
             verification_id_before], which silently turned a missing
             verification_id into the empty string and let
             [notify_approve_verification] proceed against an invalid
             id.  An Approve_verification action without a preceding
             AwaitingVerification record is a logical invariant
             violation — log it so dashboards surface the drift
             instead of acting on empty strings. *)
          (match verification_id_before with
           | None ->
             task_log_warn ~task_id
               "approve_verification action for task %s without verification_id_before (skipping notify)"
               task_id
           | Some verification_id ->
             (Atomic.get Workspace_hooks.verification_notify_verdict_fn)
               ~task_id ~verifier:ctx.agent_name ~verification_id
               ~decision:(`Approve notes))
        | Masc_domain.Reject_verification ->
          let reason = if not (String.equal notes "") then notes else reason in
          (match verification_id_before with
           | None ->
             task_log_warn ~task_id
               "reject_verification action for task %s without verification_id_before (skipping notify)"
               task_id
           | Some verification_id ->
             (Atomic.get Workspace_hooks.verification_notify_verdict_fn)
               ~task_id ~verifier:ctx.agent_name ~verification_id
               ~decision:(`Reject reason))
        | Masc_domain.Claim | Masc_domain.Start | Masc_domain.Done_action | Masc_domain.Cancel | Masc_domain.Release
        | Masc_domain.Mark_operator_blocked | Masc_domain.Unblock -> ())
   | Error err ->
       log_task_transition_failed ~agent_name:ctx.agent_name err);
  (* Record metrics *)
  (match result, action with
   | Ok _, Masc_domain.Done_action ->
       (Atomic.get Workspace_hooks.record_task_metric_fn)
         ctx.config
         ~agent_id:ctx.agent_name
         ~task_id
         ~started_at:started_at_actual
         ~completed_at:(Some (Time_compat.now ()))
         ~success:true
         ~error_message:None
         ~collaborators:collaborators_from_task
         ~handoff_from:None
         ~handoff_to:None;
        (Atomic.get Workspace_hooks.record_thompson_result_fn)
          ~agent_name:ctx.agent_name
          ~success:true
          ~reason:None;
        ()
   | Ok _, Masc_domain.Cancel ->
       (Atomic.get Workspace_hooks.record_task_metric_fn)
         ctx.config
         ~agent_id:ctx.agent_name
         ~task_id
         ~started_at:started_at_actual
         ~completed_at:(Some (Time_compat.now ()))
         ~success:false
         ~error_message:(Some (if String.equal reason "" then "Cancelled" else reason))
         ~collaborators:collaborators_from_task
         ~handoff_from:None
         ~handoff_to:None;
        (Atomic.get Workspace_hooks.record_thompson_result_fn)
          ~agent_name:ctx.agent_name
          ~success:false
          ~reason:(Some "task_cancelled");
        ()
   | Ok _, (Masc_domain.Claim | Masc_domain.Start | Masc_domain.Submit_for_verification
            | Masc_domain.Approve_verification | Masc_domain.Reject_verification | Masc_domain.Release
            | Masc_domain.Mark_operator_blocked | Masc_domain.Unblock)
   | Error _, _ -> ());
  result_to_response ~tool_name ~start_time result

let handle_update_priority ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  let priority = get_int args "priority" 3 in
  Tool_result.ok ~tool_name ~start_time (Workspace.update_priority ctx.config ~task_id ~priority)

let handle_tasks ~tool_name ~start_time ctx args =
  let include_done = get_bool args "include_done" false in
  let include_cancelled = get_bool args "include_cancelled" false in
  let status =
    match args |> Json_util.assoc_member_opt "status" |> Option.value ~default:`Null with
    | `String s when not (String.equal s "") -> Some s
    | _ -> None
  in
  Tool_result.ok ~tool_name ~start_time (Workspace.list_tasks ctx.config ~include_done ~include_cancelled ?status)

let read_event_lines config ~limit =
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
              collected := line :: !collected;
              decr remaining;
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
  let scan_limit = min 500 (limit * 5) in
  let lines = read_event_lines config ~limit:scan_limit in
  let (parsed, _malformed) =
    Fs_compat.parse_jsonl_lines ~source:"task_events" lines
  in
  let matches_task json =
    let task = Json_util.get_string json "task" in
    let task_id_field = Json_util.get_string json "task_id" in
    match task, task_id_field with
    | Some t, _ when String.equal t task_id -> true
    | _, Some t when String.equal t task_id -> true
    | _ -> false
  in
  let rec take n xs =
    match xs with
    | [] -> []
    | _ when n <= 0 -> []
    | x :: rest -> x :: take (n - 1) rest
  in
  let events = parsed |> List.filter matches_task |> take limit in
  `List events

let handle_task_history ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  let limit = get_int args "limit" 50 in
  Tool_result.ok ~tool_name ~start_time (Yojson.Safe.to_string (task_history_events_json ctx.config ~task_id ~limit))

include Tool_task_schemas
(* Dispatch function *)
let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Time_compat.now () in
  match name with
  | "masc_add_task" -> Some (handle_add_task ~tool_name:name ~start_time:start ctx args)
  | "masc_batch_add_tasks" -> Some (handle_batch_add_tasks ~tool_name:name ~start_time:start ctx args)
  | "keeper_task_claim" ->
      let task_id = get_string args "task_id" "" in
      if String.equal task_id ""
      then Some (handle_claim_next ~tool_name:name ~start_time:start ctx args)
      else Some (handle_claim ~tool_name:name ~start_time:start ctx args)
  | "masc_transition" -> Some (handle_transition ~tool_name:name ~start_time:start ctx args)
  | "masc_update_priority" -> Some (handle_update_priority ~tool_name:name ~start_time:start ctx args)
  | "masc_task_set_goal" -> Some (handle_set_goal ~tool_name:name ~start_time:start ctx args)
  | "masc_tasks" -> Some (handle_tasks ~tool_name:name ~start_time:start ctx args)
  | "masc_task_history" -> Some (handle_task_history ~tool_name:name ~start_time:start ctx args)
  | _ -> None
