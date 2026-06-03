(* Helpers, context, add_task, batch_add, claim, claim_next, release —
   extracted to [Tool_task_handlers] (godfile decomp). *)

open Tool_args
include Tool_task_handlers

let rec handle_done ~tool_name ~start_time ctx args =
  let notes = get_string args "notes" "" in
  handle_transition ~tool_name ~start_time ctx
    (`Assoc
       [
         ("task_id", Json_util.assoc_member_opt "task_id" args |> Option.value ~default:`Null);
         ("action", `String "done");
         ("notes", `String notes);
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
       Log.Task.error ~keeper_name:task_id "metrics record failed: %s" (Masc_domain.masc_error_to_string err));
  result_to_response ~tool_name ~start_time result

and handle_transition ~tool_name ~start_time ctx args =
  (* Underscore-prefixed keys (e.g. "_agent_name") are internal protocol markers
     injected by the HTTP transport and dashboard client for identity
     propagation. They are consumed upstream in Client_identity and must not
     trigger the strict-schema "Unknown argument(s)" rejection here. *)
  let is_internal_marker k =
    String.length k > 0 && Char.equal k.[0] '_'
  in
  let normalize_args = function
    | `Assoc kvs ->
      (* Transport-level alias [pr_url] is hoisted into the typed
         [handoff_context.evidence_refs] list. Previously this aliased
         into a "PR: <url>" string blob inside [notes], which the
         downstream task-handoff schema then had to recover via
         sibling synthesis or substring scanning. There is no
         in-repo reader of that [notes] blob — pr_url consumers
         (tool_call_log, owner_hooks, audit_...)
         already read pr_url as a typed field elsewhere — so the
         legacy blob is dead-on-write.

         Merge semantics: if a [handoff_context] object is already
         present in args, append pr_url to its [evidence_refs]
         (preserving any existing refs). Otherwise inject a new
         minimal handoff_context = { evidence_refs = [pr_url] }. *)
      let kvs =
        match List.find_opt (fun (k, _) -> String.equal k "pr_url") kvs with
        | Some (_, `String pr_url) when not (String.equal pr_url "") ->
            let kvs = List.filter (fun (k, _) -> not (String.equal k "pr_url")) kvs in
            let merge_pr_url_into_handoff (hc : Yojson.Safe.t) : Yojson.Safe.t =
              match hc with
              | `Assoc hc_fields ->
                let existing_refs =
                  match List.assoc_opt "evidence_refs" hc_fields with
                  | Some (`List xs) -> xs
                  | _ -> []
                in
                let new_refs = existing_refs @ [ `String pr_url ] in
                let hc_fields =
                  List.filter
                    (fun (k, _) -> not (String.equal k "evidence_refs"))
                    hc_fields
                  @ [ "evidence_refs", `List new_refs ]
                in
                `Assoc hc_fields
              | _ -> `Assoc [ "evidence_refs", `List [ `String pr_url ] ]
            in
            (match List.find_opt (fun (k, _) -> String.equal k "handoff_context") kvs with
             | Some _ ->
               List.map
                 (fun (k, v) ->
                   if String.equal k "handoff_context"
                   then ("handoff_context", merge_pr_url_into_handoff v)
                   else (k, v))
                 kvs
             | None ->
               kvs @ [ "handoff_context", merge_pr_url_into_handoff `Null ])
        | Some _ -> List.filter (fun (k, _) -> not (String.equal k "pr_url")) kvs
        | None -> kvs
      in
      `Assoc kvs
    | other -> other
  in
  let args = normalize_args args in
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
        Log.Task.warn ~keeper_name:task_id "[anti-rationalization] force=true rejected: agent=%s lacks admin privilege"
          ctx.agent_name;
        false
      )
    else false
  in
  let tasks = Workspace.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks in
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
  match client_side_transition_gate_error ~task_opt ~action ~action_s with
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
  let completion_state_error =
    if (=) action Masc_domain.Done_action && not force then
      completion_state_error ~task_id ~agent_name:ctx.agent_name ~task_opt
    else
      None
  in
  match completion_state_error with
  | Some err ->
    log_task_transition_failed ~agent_name:ctx.agent_name err;
    result_to_response ~tool_name ~start_time (Error err)
  | None ->
  let completion_owned_by_caller =
    force || can_review_completion ~task_opt ~agent_name:ctx.agent_name
  in
  let done_redirects_to_verification =
    (=) action Masc_domain.Done_action
    && Env_config_runtime.Verification.fsm_enabled ()
    && completion_owned_by_caller
    && task_requires_verification task_opt
  in
  let persisted_gate_rejection =
    if (=) action Masc_domain.Done_action
       && not force
       && not done_redirects_to_verification
    then
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
          ~ctx
          ~task_opt
          ~task_id
          ~notes
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
  (* Verifier gate: if the task has a completion_contract and the
     verification FSM is enabled, redirect Done → Submit_for_verification
     so a cross-agent verifier can independently validate the
     quantitative criteria. Gates 1-3 (length, excuse, LLM) still run
     above; this replaces Gate 2.5 (substring match) with real
     measurement by the verifier. See issue #7598. *)
  let action =
    if done_redirects_to_verification then
      match task_opt with
      | Some task ->
        (match task.contract with
         | Some contract when contract_requires_verification contract ->
           Log.Task.info
             ~keeper_name:task_id
             "[verifier-gate] redirecting Done→Submit_for_verification task=%s agent=%s contract_items=%d"
             task_id ctx.agent_name
             (List.length contract.completion_contract
              + List.length contract.required_evidence
              + List.length contract.verify_gate_evidence);
           Masc_domain.Submit_for_verification
         | _ -> action)
      | None -> action
    else action
  in
  (* RFC-0109 Phase D hard cut: contracted verification submissions
     require a typed CDAL verdict. Analysis-only tasks (no contract)
     bypass the gate. *)
  let evidence_decision =
    let needs_gate =
      match requested_action with
      | Masc_domain.Submit_for_verification
      | Masc_domain.Submit_pr_evidence -> true
      | Masc_domain.Done_action when done_redirects_to_verification -> true
      | Masc_domain.Claim
      | Masc_domain.Start
      | Masc_domain.Done_action
      | Masc_domain.Cancel
      | Masc_domain.Release
      | Masc_domain.Approve_verification
      | Masc_domain.Reject_verification ->
        false
    in
    if not needs_gate then Workspace_hooks.Pass
    else
      (Atomic.get Workspace_hooks.cdal_evidence_gate_decide_fn)
        ~task_id
        ~task_opt
        ~notes
        ~handoff:(Option.map Masc_domain.task_handoff_context_to_yojson handoff_context)
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
         ~scope_policy:"block_scope"
         ~extra_fields
         reason)
  | Workspace_hooks.Pass ->
  let action =
    match requested_action, task_opt with
    | ( Masc_domain.Submit_for_verification
      , Some ({ task_status = Masc_domain.Todo; _ } : Masc_domain.task) ) ->
      Log.Task.info
        ~keeper_name:task_id
        "[verification-alias] treating todo submit_for_verification with evidence as submit_pr_evidence task=%s agent=%s"
        task_id
        ctx.agent_name;
      Masc_domain.Submit_pr_evidence
    | _ -> action
  in
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
  let is_version_mismatch = function
    | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState msg)) ->
        let prefix = "Version mismatch" in
        String.length msg >= String.length prefix
        && String.equal (Stdlib.String.sub msg 0 (String.length prefix)) prefix
    | _ -> false
  in
  let prepare_verification_request =
    match action with
    | Masc_domain.Submit_for_verification | Masc_domain.Submit_pr_evidence ->
      Some
        (fun ~task ~assignee ~verification_id ~evidence_refs ->
           (Atomic.get Workspace_hooks.verification_create_submit_request_fn)
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
    | Masc_domain.Reject_verification ->
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
             (Atomic.get Workspace_hooks.verification_record_approve_fn)
               ctx.config
               ~task_id:task.id
               ~verifier
               ~verification_id
               ~notes
           | `Reject reason ->
             (Atomic.get Workspace_hooks.verification_record_reject_fn)
               ctx.config
               ~task_id:task.id
               ~verifier
               ~verification_id
               ~reason)
    | Masc_domain.Claim
    | Masc_domain.Start
    | Masc_domain.Done_action
    | Masc_domain.Cancel
    | Masc_domain.Release
    | Masc_domain.Submit_for_verification
    | Masc_domain.Submit_pr_evidence ->
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
      let ev = if attempt = 0 then expected_version else None in
      let r = Workspace.transition_task_r ctx.config ~agent_name:ctx.agent_name
                ~task_id ~action ?expected_version:ev ~notes ~reason
                ?handoff_context ?prepare_verification_request
                ?prepare_verification_verdict () in
      if is_version_mismatch r && attempt < max_cas_retries then begin
        Log.Task.info ~keeper_name:task_id "CAS version mismatch on %s (attempt %d/%d), retrying in %.0fms"
          task_id (attempt + 1) max_cas_retries (cas_retry_delay_s *. 1000.0);
        Time_compat.sleep cas_retry_delay_s;
        try_transition (attempt + 1)
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
        | Masc_domain.Submit_for_verification | Masc_domain.Submit_pr_evidence ->
          let tasks = Workspace.get_tasks_raw ctx.config in
          (match List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks with
           | Some task ->
             let evidence_refs = verification_evidence_refs_for_task task in
             (match task.task_status with
              | Masc_domain.AwaitingVerification { verification_id; assignee; _ } ->
                (Atomic.get Workspace_hooks.verification_notify_submit_fn)
                  ctx.config
                  ~task
                  ~assignee
                  ~verification_id
                  ~evidence_refs
              | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
              | Masc_domain.Done _ | Masc_domain.Cancelled _ -> ())
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
             Log.Task.warn
               ~keeper_name:task_id
               "approve_verification action for task %s without verification_id_before (skipping notify)"
               task_id
           | Some verification_id ->
             (Atomic.get Workspace_hooks.verification_notify_approve_fn)
               ~task_id ~verifier:ctx.agent_name ~verification_id ~notes)
        | Masc_domain.Reject_verification ->
          let reason = if not (String.equal notes "") then notes else reason in
          (match verification_id_before with
           | None ->
             Log.Task.warn
               ~keeper_name:task_id
               "reject_verification action for task %s without verification_id_before (skipping notify)"
               task_id
           | Some verification_id ->
             (Atomic.get Workspace_hooks.verification_notify_reject_fn)
               ~task_id ~verifier:ctx.agent_name ~verification_id ~reason)
        | Masc_domain.Claim | Masc_domain.Start | Masc_domain.Done_action | Masc_domain.Cancel | Masc_domain.Release -> ())
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
            | Masc_domain.Submit_pr_evidence
            | Masc_domain.Approve_verification | Masc_domain.Reject_verification | Masc_domain.Release)
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
      let content = Fs_compat.load_file path in
      String.split_on_char '\n' content |> List.filter (fun s -> s <> "")
    in
    let add_lines path =
      if !remaining <= 0
      then ()
      else (
        let lines = read_lines path in
        let rec take = function
          | [] -> ()
          | line :: rest ->
            if !remaining > 0
            then (
              collected := line :: !collected;
              decr remaining;
              take rest)
        in
        take (List.rev lines))
    in
    List.iter
      (fun month ->
         if !remaining > 0
         then (
           let month_path = Filename.concat events_dir month in
           if Sys.file_exists month_path && Sys.is_directory month_path
           then
             Sys.readdir month_path
             |> Array.to_list
             |> List.sort compare
             |> List.rev
             |> List.iter (fun file ->
               if !remaining > 0
               then (
                 let path = Filename.concat month_path file in
                 if Sys.file_exists path then add_lines path))))
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
  | "masc_claim_next" -> Some (handle_claim_next ~tool_name:name ~start_time:start ctx args)
  | "masc_transition" -> Some (handle_transition ~tool_name:name ~start_time:start ctx args)
  | "masc_update_priority" -> Some (handle_update_priority ~tool_name:name ~start_time:start ctx args)
  | "masc_tasks" -> Some (handle_tasks ~tool_name:name ~start_time:start ctx args)
  | "masc_task_history" -> Some (handle_task_history ~tool_name:name ~start_time:start ctx args)
  | _ -> None
