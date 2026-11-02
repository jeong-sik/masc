open Alcotest
module Goals = Masc.Workspace_goals
module GP = Goal_phase

let rec remove_tree path =
  if Sys.is_directory path then (
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path

let with_workspace run =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let path = Filename.temp_file "goal-suspension-" "" in
  Sys.remove path; Unix.mkdir path 0o700;
  let config = Workspace_utils.default_config_uncached path in
  Fs_compat.mkdir_p (Workspace_utils.masc_dir config);
  let wakes = ref 0 in
  let old = Atomic.exchange Workspace_hooks.goal_verification_pending_fn
    (fun _ ~goal_id:_ -> incr wakes) in
  Fun.protect ~finally:(fun () ->
      Atomic.set Workspace_hooks.goal_verification_pending_fn old;
      remove_tree path)
    (fun () -> run config wakes)

let success result =
  if not (Tool_result.is_success result) then fail (Tool_result.message result);
  Yojson.Safe.from_string (Tool_result.message result)
let refused result = check bool (Tool_result.message result) false (Tool_result.is_success result)
let saved config id = match Goal_store.find_goal config ~goal_id:id with
  | Goal_found goal -> goal
  | Goal_absent -> fail "Goal missing"
  | Store_unavailable error -> fail (Goal_store.unavailable_to_string error)
let state config = match Goal_store.load_source config with
  | Available state -> state
  | Uninitialized -> fail "missing store"
  | Unavailable error -> fail (Goal_store.unavailable_to_string error)
let create config =
  match Goal_store.upsert_goal config ~title:"Suspension scenario"
      ~metric:"observed successful requests" ~target_value:"1" () with
  | Ok (goal, _) -> goal
  | Error error -> fail (Goal_store.write_error_to_string error)
let phase expected goal = check bool (GP.to_string expected) true (goal.Goal_store.phase = expected)
let transition config id action =
  let ctx : Masc.Workspace_types.context = { config; agent_name = "operator" } in
  Goals.handle_goal_transition ~tool_name:"masc_goal_transition"
    ~start_time:(Tool_timing.start ()) ctx
    (`Assoc (["goal_id", `String id; "action", `String action]
             (* A drop must say why; the other actions take no note here. *)
             @ (if action = "drop" then ["note", `String "scenario no longer needs this Goal"] else [])))
let change config id action = ignore (transition config id action |> success)
let proof config id = match Goal_verification.get_record_authoritative config ~goal_id:id with
  | Ok (Some record) -> record
  | Ok None -> fail "no proof" | Error detail -> fail detail
let pending config id = match (proof config id).completion with
  | Goal_verification.Proof_pending pending -> pending.request_id, pending.criterion
  | _ -> fail "proof is not pending"
let commit ?before_proof_commit config (goal : Goal_store.goal) (request_id, criterion) run decision =
  Goals.commit_verifier_decision ?before_proof_commit
    ~tool_name:"internal_verifier" ~start_time:(Tool_timing.start ()) config
    ~goal_id:goal.id ~verification_run_id:run ~request_id
    ~criterion ~decision ~evidence:"measured evidence"
let set_phase config goal phase =
  match Goal_store.transact_goal config ~goal_id:goal.Goal_store.id
      (fun current -> Ok ({ current with phase }, ())) with
  | Ok _ -> () | Error error -> fail (Goal_store.write_error_to_string error)

let test_transition_refuses_ids_that_would_be_retargeted () = with_workspace @@ fun config wakes ->
  let canonical = create config in
  let padded = {canonical with id=" " ^ canonical.id ^ " "; title="Imported Goal"} in
  let original = state config in
  (match Goal_store.write_state_result config {original with goals=[canonical; padded]} with
   | Ok () -> () | Error detail -> fail detail);
  let primary = Goal_store.goals_path config in
  let mirror = primary ^ ".last-good" in
  let proof_path = Goal_verification.verifications_path config in
  let read_optional path = if Sys.file_exists path then Some (Fs_compat.load_file path) else None in
  let before = Fs_compat.load_file primary, Fs_compat.load_file mirror in
  let proof_before = read_optional proof_path in
  let refused_before_effect (result : Tool_result.result) =
    (match result with
     | Tool_result.Failed { class_ = Tool_result.Policy_rejection;
                            effect_disposition = Tool_result.Proven_pre_effect; _ } -> ()
     | Tool_result.Failed _ | Tool_result.Completed _ | Tool_result.Deferred _ ->
       fail "ID rejection did not prove a pre-effect policy refusal");
    let body = Yojson.Safe.from_string (Tool_result.message result) in
    check bool "failure data retains the error envelope" true (Tool_result.data result = body);
    check string "failure status" "error" Yojson.Safe.Util.(member "status" body |> to_string);
    check string "failure code" "validation_error" Yojson.Safe.Util.(member "error_code" body |> to_string)
  in
  List.iter (fun id ->
    List.iter (fun action -> refused_before_effect (transition config id action))
      ["pause"; "block"; "drop"; "request_complete"])
    [padded.id; " " ^ canonical.id; canonical.id ^ " "; "\t" ^ canonical.id];
  let ctx : Masc.Workspace_types.context = { config; agent_name = "operator" } in
  List.iter (fun ids ->
    let result = Goals.handle_goal_transition ~tool_name:"masc_goal_transition"
      ~start_time:(Tool_timing.start ()) ctx
      (`Assoc (ids @ ["action", `String "pause"])) in
    refused_before_effect result)
    [ ["goal_id", `String canonical.id; "goal_id", `String padded.id]
    ; ["goal_id", `String padded.id; "goal_id", `String canonical.id]
    ; ["goal_id", `String canonical.id; "goal_id", `String canonical.id]
    ; ["goal_id", `String canonical.id; "goal_id", `Int 3]
    ; ["goal_id", `Null; "goal_id", `String canonical.id] ];
  List.iter (fun value ->
    let result = transition config value "pause" in
    refused result;
    let body = Yojson.Safe.from_string (Tool_result.message result) in
    match Yojson.Safe.Util.member "field_errors" body with
    | `List [error] ->
      check string "blank ID keeps the field name" "goal_id"
        Yojson.Safe.Util.(member "field" error |> to_string);
      check string "blank ID keeps the nonempty constraint" "non_empty"
        Yojson.Safe.Util.(member "constraint" error |> to_string)
    | _ -> fail "blank ID lost its structured field error") [""; "  "];
  check string "primary unchanged by refused transitions" (fst before) (Fs_compat.load_file primary);
  check string "mirror unchanged by refused transitions" (snd before) (Fs_compat.load_file mirror);
  check (option string) "proof unchanged by refused transitions" proof_before (read_optional proof_path);
  check int "no verification wake for a refused target" 0 !wakes;
  phase GP.Executing (saved config canonical.id);
  phase GP.Executing (saved config padded.id);
  change config canonical.id "pause";
  phase (GP.Paused GP.Resume_executing) (saved config canonical.id);
  phase GP.Executing (saved config padded.id)

let test_restore_matrix () = with_workspace @@ fun config _ ->
  List.iter (fun (live, target) ->
    List.iter (fun first ->
      let goal = create config in
      set_phase config goal live;
      change config goal.id first;
      let suspended = if first = "pause" then GP.Paused target else GP.Blocked target in
      phase suspended (saved config goal.id);
      check bool "storage round trip retains full lifecycle" true
        (GP.of_fields (Goal_store.goal_to_yojson (saved config goal.id)) = Ok suspended);
      let before = Fs_compat.load_file (Goal_store.goals_path config) in
      let repeated = transition config goal.id first |> success in
      let open Yojson.Safe.Util in
      check bool "repeated suspension is a no-op" true (member "noop" repeated |> to_bool);
      let returned_goal = member "goal" repeated in
      check string "repeated response keeps the public Goal phase a string"
        (GP.to_string suspended) (member "phase" returned_goal |> to_string);
      check string "repeated response keeps the restore target beside phase"
        (GP.to_string live) (member "resume_phase" returned_goal |> to_string);
      (match member "phase" repeated with
       | `Null -> ()
       | `String value -> check string "optional top-level phase remains a string"
           (GP.to_string suspended) value
       | _ -> fail "idempotent response changed the public phase field to an object");
      check string "same suspension does not rewrite" before (Fs_compat.load_file (Goal_store.goals_path config));
      change config goal.id "block"; phase (GP.Blocked target) (saved config goal.id);
      refused (transition config goal.id "resume");
      change config goal.id "pause"; phase (GP.Paused target) (saved config goal.id);
      refused (transition config goal.id "unblock");
      change config goal.id "resume"; phase live (saved config goal.id)) ["pause";"block"])
    [GP.Executing, GP.Resume_executing; GP.Verifying, GP.Resume_verifying;
     GP.Awaiting_confirmation, GP.Resume_awaiting_confirmation]

let test_terminal_and_escape () = with_workspace @@ fun config _ ->
  List.iter (fun terminal ->
    let goal = create config in set_phase config goal terminal;
    List.iter (fun action -> refused (transition config goal.id action); phase terminal (saved config goal.id))
      ["pause";"block";"resume";"unblock"];
    change config goal.id "reopen"; phase GP.Executing (saved config goal.id)) [GP.Completed; GP.Dropped];
  List.iter (fun suspension ->
    let goal = create config in change config goal.id suspension;
    change config goal.id "drop"; phase GP.Dropped (saved config goal.id);
    change config goal.id "reopen"; phase GP.Executing (saved config goal.id)) ["pause";"block"]

let test_bound_result () = with_workspace @@ fun config wakes ->
  List.iter (fun (suspend, restore) ->
    List.iter (fun decision ->
      let goal = create config in
      change config goal.id "request_complete";
      let request = pending config goal.id in
      (match Goal_verification.bind_review config ~goal_id:goal.id with
       | Ok (_, (request_id, _, _)) -> check string "bound existing request" (fst request) request_id
       | Error error -> fail (Goal_verification.review_binding_error_to_string error));
      change config goal.id suspend;
      check bool "daemon binding rejects suspended Goal" true
        (Result.is_error (Goal_verification.bind_review config ~goal_id:goal.id));
      let before = saved config goal.id in
      let version = (state config).version in
      let candles = ref 0 in
      let before_proof_commit _ _ =
        incr candles;
        ignore (pending config goal.id);
        Ok () in
      let result = commit ~before_proof_commit config goal request "bound-review" decision |> success in
      check bool "Goal unchanged by bound result" true (before = saved config goal.id);
      check int "no Goal rewrite or completion notice" version (state config).version;
      check int "no completion notifications" 0 (List.length (state config).pending_notifications);
      check bool "proof committed" true (Yojson.Safe.Util.member "verification" result <> `Null);
      ignore (commit ~before_proof_commit config goal request "bound-review" decision |> success);
      refused (commit ~before_proof_commit config goal request "different-run" decision);
      check int "Candle exactly once for proven" (match decision with Goals.Proof_proven -> 1 | Proof_refuted _ -> 0) !candles;
      refused (transition config goal.id "request_complete");
      (match Goals.recover_current_proof config ~goal_id:goal.id with
       | Ok false -> () | _ -> fail "suspended Goal admitted new verifier work");
      let wake_count = !wakes in
      change config goal.id restore;
      check int "restore explicitly wakes verifier" (wake_count + 1) !wakes;
      phase GP.Verifying (saved config goal.id);
      (match Goals.reconcile_committed_proof config ~goal_id:goal.id with
       | Ok (Goals.Reconciled _) -> () | _ -> fail "restored proof was not reconciled");
      phase (match decision with Goals.Proof_proven -> GP.Awaiting_confirmation | Proof_refuted _ -> GP.Executing)
        (saved config goal.id);
      (* No recipients in this isolated workspace. Drain durable notices. *)
      List.iter (fun notice ->
        ignore (Goal_store.snapshot_notification_recipients config notice ~recipients:[]);
        ignore (Goal_store.acknowledge_notification config notice))
        (state config).pending_notifications)
      [Goals.Proof_proven; Goals.Proof_refuted {reason="target not reached"}])
    ["pause","resume"; "block","unblock"]

let test_edit_suspended () = with_workspace @@ fun config _ ->
  List.iter (fun suspension ->
    let goal = create config in change config goal.id "request_complete";
    let request = pending config goal.id in change config goal.id suspension;
    (match Goal_store.upsert_goal config ~id:goal.id ~target_value:"2" () with
     | Ok _ -> () | Error error -> fail (Goal_store.write_error_to_string error));
    phase (if suspension = "pause" then GP.Paused GP.Resume_executing else GP.Blocked GP.Resume_executing)
      (saved config goal.id);
    refused (commit config goal request "old-criterion" Goals.Proof_proven);
    change config goal.id (if suspension = "pause" then "resume" else "unblock");
    phase GP.Executing (saved config goal.id);
    change config goal.id "request_complete";
    check bool "new request after criterion edit" true (fst request <> fst (pending config goal.id)))
    ["pause";"block"]

let test_confirmation_restores_binding () = with_workspace @@ fun config _ ->
  let goal = create config in change config goal.id "request_complete";
  let request_id, criterion = pending config goal.id in
  ignore (commit config goal (request_id, criterion) "proven-review" Goals.Proof_proven |> success);
  change config goal.id "pause";
  phase (GP.Paused GP.Resume_awaiting_confirmation) (saved config goal.id);
  let confirm () = Goals.confirm_completion config ~goal_id:goal.id ~operator_id:"operator"
    ~request_id ~verification_run_id:"proven-review" ~criterion_revision:goal.criterion_revision in
  check bool "suspension refuses human completion" true (Result.is_error (confirm ()));
  change config goal.id "block"; change config goal.id "unblock";
  phase GP.Awaiting_confirmation (saved config goal.id);
  check bool "restored exact proof can be confirmed" true (Result.is_ok (confirm ()));
  phase GP.Completed (saved config goal.id)

let test_candle_failure () = with_workspace @@ fun config _ ->
  let goal = create config in change config goal.id "request_complete";
  let request = pending config goal.id in change config goal.id "pause";
  let before = Fs_compat.load_file (Goal_store.goals_path config) in
  refused (commit ~before_proof_commit:(fun _ _ -> Error "Candle store unavailable")
    config goal request "bound-review" Goals.Proof_proven);
  check string "failed Candle leaves suspension untouched" before (Fs_compat.load_file (Goal_store.goals_path config));
  check bool "failed Candle leaves proof pending" true (request = pending config goal.id);
  change config goal.id "resume";
  check bool "daemon binding reopens exact pending request" true
    (Result.is_ok (Goal_verification.bind_review config ~goal_id:goal.id))

let test_codec_and_rollup () = with_workspace @@ fun config _ ->
  List.iter (fun (p, target) ->
    let row = `Assoc ["phase", `String p; "resume_phase", target] in
    check bool "invalid lifecycle rejected" true (Result.is_error (GP.of_fields row)))
    ["paused", `Null; "blocked", `String "completed"; "executing", `String "verifying"; "dropped", `String "executing"];
  List.iter (fun phase -> let goal = create config in set_phase config goal phase) GP.all;
  let rollup = Goal_store.compute_rollup (state config).goals in
  check int "paused count" 3 rollup.paused_count;
  check int "blocked count" 3 rollup.blocked_count;
  check int "active count excludes suspended" 1 rollup.active_count;
  (match Goal_store.list_goals_result config ~kind:GP.Kind.Paused () with
   | Ok goals -> check int "phase filter includes every restore target" 3 (List.length goals)
   | Error _ -> fail "filter rejected");
  List.iter (fun phase -> check bool "suspension excludes Goal self-directed progress" false
    (GP.admits_self_directed_progress phase))
    [GP.Paused GP.Resume_executing; GP.Blocked GP.Resume_verifying]

let add_task ?goal_id config title =
  match Masc.Workspace.add_task_with_result ?goal_id config ~title ~priority:2 ~description:"" with
  | Ok created -> created.Masc.Workspace.task_id
  | Error error -> fail (Masc.Workspace.add_task_error_to_string error)
let task_status config id =
  match List.find_opt (fun (task : Masc_domain.task) -> task.id = id) (Masc.Workspace.get_tasks_raw config) with
  | Some task -> task.task_status
  | None -> fail ("missing " ^ id)
let ok_or_fail = function Ok _ -> () | Error error -> fail (Masc_domain.masc_error_to_string error)
let drop_field json key = Yojson.Safe.Util.(json |> member "tasks" |> member key |> to_list)
let failed_task_ids json = drop_field json "cancel_failed" |> List.map (fun row ->
  Yojson.Safe.Util.(row |> member "task_id" |> to_string))
let failed_task_errors json = drop_field json "cancel_failed" |> List.map (fun row ->
  Yojson.Safe.Util.(row |> member "error" |> to_string))
let contains ~sub text =
  let n = String.length sub in
  let rec go i = i + n <= String.length text && (String.sub text i n = sub || go (i + 1)) in
  go 0
let backlog config = match Workspace_backlog.read_backlog_r config with
  | Ok value -> value
  | Error detail -> fail detail
let save_atomic path contents = match Fs_compat.save_file_atomic path contents with
  | Ok () -> ()
  | Error detail -> fail detail
let ordered_tasks config ids =
  (backlog config).tasks |> List.filter_map (fun (task : Masc_domain.task) ->
    if List.mem task.id ids then Some task.id else None) |> List.sort String.compare

let test_drop_cancels_left_over_todo () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  let live = match Goal_store.upsert_goal config ~title:"Still live" ~metric:"m" ~target_value:"1" () with
    | Ok (goal, _) -> goal | Error error -> fail (Goal_store.write_error_to_string error) in
  let todo = add_task ~goal_id:goal.id config "orphaned todo" in
  let shared = add_task ~goal_id:goal.id config "also serves a live goal" in
  (match Workspace_goal_index.link_task_to_goal_result config ~goal_id:live.id ~task_id:shared with
   | Ok _ -> () | Error _ -> fail "link to the live goal");
  let held = add_task ~goal_id:goal.id config "held work" in
  Masc.Workspace.transition_task_r config ~agent_name:"holder" ~task_id:held ~action:Masc_domain.Claim ()
  |> ok_or_fail;
  let unlinked = add_task config "unlinked" in
  let json = transition config goal.id "drop" |> success in
  check (list string) "only the orphaned todo is cancelled" [todo]
    (drop_field json "cancelled" |> List.map Yojson.Safe.Util.to_string);
  check int "nothing failed to cancel" 0 (List.length (drop_field json "cancel_failed"));
  check (list string) "the held task is named with its holder" [held ^ "/holder"]
    (drop_field json "held" |> List.map (fun row -> Yojson.Safe.Util.(
       to_string (member "task_id" row) ^ "/" ^ to_string (member "holder" row))));
  (match task_status config todo with
   | Masc_domain.Cancelled { cancelled_by; reason = Some reason; _ } ->
       check string "cancelled by the dropping actor" "operator" cancelled_by;
       check string "the reason names the goal" (Printf.sprintf "Goal %s was dropped: scenario no longer needs this Goal" goal.id) reason
   | _ -> fail "orphaned todo was not cancelled with a reason");
  (match task_status config shared, task_status config held, task_status config unlinked with
   | Masc_domain.Todo, Masc_domain.Claimed { assignee = "holder"; _ }, Masc_domain.Todo -> ()
   | _ -> fail "a task outside the dropped goal's leftovers changed");
  (* No recipients in this isolated workspace, so the notice stays pending. *)
  let contains ~sub text =
    let n = String.length sub in
    let rec go i = i + n <= String.length text && (String.sub text i n = sub || go (i + 1)) in
    go 0 in
  (match (state config).pending_notifications with
   | [ notice ] ->
       check bool "the drop notice names the held task and its holder" true
         (contains ~sub:"[goal_dropped]" notice.content && contains ~sub:(held ^ " (holder)") notice.content)
   | notices -> fail (Printf.sprintf "expected one drop notice, got %d" (List.length notices)));
  let again = transition config goal.id "drop" |> success in
  check bool "a repeated drop is a no-op" true Yojson.Safe.Util.(again |> member "noop" |> to_bool);
  check bool "a no-op drop reports no task work" true Yojson.Safe.Util.(again |> member "tasks" = `Null)

let test_drop_cancels_multiple_from_independent_reads () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  let first = add_task ~goal_id:goal.id config "first candidate" in
  let second = add_task ~goal_id:goal.id config "second candidate" in
  let version = (backlog config).version in
  let json = transition config goal.id "drop" |> success in
  check (list string) "both candidates cancelled" (List.sort String.compare [first; second])
    (drop_field json "cancelled" |> List.map Yojson.Safe.Util.to_string |> List.sort String.compare);
  check int "no Task cancellation failures" 0 (List.length (failed_task_ids json));
  check int "each committed Task advanced the backlog once" (version + 2) (backlog config).version;
  List.iter (fun id -> match task_status config id with
      | Masc_domain.Cancelled { cancelled_by; _ } -> check string "cancelled by operator" "operator" cancelled_by
      | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
      | Masc_domain.AwaitingVerification _ | Masc_domain.Done _ -> fail ("Task was not cancelled: " ^ id)) [first; second]

let test_drop_does_not_cancel_claim_after_snapshot () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  let one = add_task ~goal_id:goal.id config "first candidate" in
  let two = add_task ~goal_id:goal.id config "second candidate" in
  let first, second = match ordered_tasks config [one; two] with
    | [first; second] -> first, second
    | [] | [_] | _ :: _ :: _ :: _ -> fail "expected two candidate rows" in
  let claim = ref None in
  let hook = Atomic.exchange Workspace_hooks.goal_verification_abandoned_fn
      (fun hook_config ~goal_id:_ ->
         claim := Some (Masc.Workspace.transition_task_r hook_config ~agent_name:"operator"
           ~task_id:first ~action:Masc_domain.Claim ())) in
  let json = Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.goal_verification_abandoned_fn hook)
      (fun () -> transition config goal.id "drop" |> success) in
  (match !claim with
   | Some (Ok _) -> ()
   | Some (Error error) -> fail (Masc_domain.masc_error_to_string error)
   | None -> fail "claim hook was not called");
  check (list string) "independent Task was cancelled" [second]
    (drop_field json "cancelled" |> List.map Yojson.Safe.Util.to_string);
  check (list string) "changed Task is reported" [first] (failed_task_ids json);
  (match failed_task_errors json with
   | [error] -> check bool "changed Task was not attempted" true (contains ~sub:"Task changed since" error)
   | [] | _ :: _ :: _ -> fail "expected one Task error");
  (match task_status config first with
   | Masc_domain.Claimed { assignee; _ } -> check string "same actor retains the claim" "operator" assignee
   | Masc_domain.Todo | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
   | Masc_domain.Done _ | Masc_domain.Cancelled _ -> fail "claimed Task was changed");
  (match task_status config second with
   | Masc_domain.Cancelled _ -> ()
   | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
   | Masc_domain.Done _ -> fail "independent Task was not cancelled");
  let repeated = transition config goal.id "drop" |> success in
  check bool "repeated drop is a no-op" true Yojson.Safe.Util.(repeated |> member "noop" |> to_bool);
  check bool "repeated drop does not retry Tasks" true Yojson.Safe.Util.(repeated |> member "tasks" = `Null)

let test_drop_preserves_new_handoff () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  let changed = add_task ~goal_id:goal.id config "changed candidate" in
  let independent = add_task ~goal_id:goal.id config "independent candidate" in
  let handoff : Masc_domain.task_handoff_context =
    { summary = "work was inspected"; reason = None; next_step = Some "continue";
      failure_mode = None; reclaim_policy = None; evidence_refs = ["note:handoff"];
      updated_at = None; updated_by = Some "operator" } in
  let hook_result = ref None in
  let hook = Atomic.exchange Workspace_hooks.goal_verification_abandoned_fn
      (fun hook_config ~goal_id:_ ->
         let claim = Masc.Workspace.transition_task_r hook_config ~agent_name:"operator" ~task_id:changed
             ~action:Masc_domain.Claim () in
         let release = match claim with
           | Error error -> Error error
           | Ok _ -> Masc.Workspace.transition_task_r hook_config ~agent_name:"operator" ~task_id:changed
                       ~action:Masc_domain.Release ~handoff_context:handoff () in
         hook_result := Some release) in
  let json = Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.goal_verification_abandoned_fn hook)
      (fun () -> transition config goal.id "drop" |> success) in
  (match !hook_result with
   | Some (Ok _) -> ()
   | Some (Error error) -> fail (Masc_domain.masc_error_to_string error)
   | None -> fail "claim and release hook was not called");
  check (list string) "changed Task is reported" [changed] (failed_task_ids json);
  check (list string) "unrelated candidate still cancels" [independent]
    (drop_field json "cancelled" |> List.map Yojson.Safe.Util.to_string);
  let task = match List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id changed) (backlog config).tasks with
    | Some task -> task | None -> fail "changed Task missing" in
  (match task.task_status with
   | Masc_domain.Todo -> ()
   | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
   | Masc_domain.Done _ | Masc_domain.Cancelled _ -> fail "changed Task was cancelled");
  (match task.handoff_context with
   | Some context -> check string "new handoff survives" handoff.summary context.summary
   | None -> fail "new handoff was lost")

let test_drop_cas_refuses_claim_after_fresh_read () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  let id = add_task ~goal_id:goal.id config "candidate" in
  let original = match List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id id) (backlog config).tasks with
    | Some task -> task | None -> fail "candidate missing" in
  let hook_result = ref None in
  let ctx : Masc.Workspace_types.context = { config; agent_name = "operator" } in
  let cancelled, failed = Goals.For_testing.cancel_dropped_goal_todos ctx ~goal_id:goal.id ~reason:"fixture"
      ~before_transition:(fun ~task_id ->
        hook_result := Some (Masc.Workspace.transition_task_r config ~agent_name:"operator"
          ~task_id ~action:Masc_domain.Claim ())) [original] in
  (match !hook_result with
   | Some (Ok _) -> ()
   | Some (Error error) -> fail (Masc_domain.masc_error_to_string error)
   | None -> fail "claim hook was not called");
  check (list string) "conflicted Task not reported cancelled" [] cancelled;
  (match failed with
   | [(task_id, detail)] ->
       check string "conflicted Task" id task_id;
       check bool "version conflict reported" true (contains ~sub:"Version mismatch" detail)
   | [] | _ :: _ :: _ -> fail "expected one version conflict");
  (match task_status config id with
   | Masc_domain.Claimed { assignee; _ } -> check string "claim preserved" "operator" assignee
   | Masc_domain.Todo | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
   | Masc_domain.Done _ | Masc_domain.Cancelled _ -> fail "claim was not preserved")

let test_drop_refuses_deleted_then_restored_task () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  let id = add_task ~goal_id:goal.id config "restored candidate" in
  let independent = add_task ~goal_id:goal.id config "independent candidate" in
  let original = match List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id id) (backlog config).tasks with
    | Some task -> task | None -> fail "candidate missing" in
  (match Masc.Workspace.append_archive_tasks config [original] with Ok () -> () | Error detail -> fail detail);
  let hook_result = ref None in
  let hook = Atomic.exchange Workspace_hooks.goal_verification_abandoned_fn
      (fun hook_config ~goal_id:_ ->
         let result = match Masc.Workspace.delete_task_r hook_config ~task_id:id with
           | Error error -> Error (Masc_domain.masc_error_to_string error)
           | Ok _ ->
               (try ignore (Masc.Workspace.archive_terminal_tasks hook_config ~days:1 ()); Ok () with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn -> Error (Printexc.to_string exn)) in
         hook_result := Some result) in
  let json = Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.goal_verification_abandoned_fn hook)
      (fun () -> transition config goal.id "drop" |> success) in
  (match !hook_result with Some (Ok ()) -> () | Some (Error detail) -> fail detail | None -> fail "restore hook was not called");
  check bool "deletion receipt remains" true
    (List.exists (fun (receipt : Masc_domain.task_deletion_receipt) -> String.equal receipt.deleted_task_id id)
       (backlog config).task_deletion_receipts);
  check (list string) "restored Task is refused" [id] (failed_task_ids json);
  check (list string) "independent Task still cancels" [independent]
    (drop_field json "cancelled" |> List.map Yojson.Safe.Util.to_string);
  (match task_status config id with
   | Masc_domain.Todo -> ()
   | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
   | Masc_domain.Done _ | Masc_domain.Cancelled _ -> fail "restored Task was changed")

let test_drop_continues_after_post_commit_error () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  let one = add_task ~goal_id:goal.id config "first candidate" in
  let two = add_task ~goal_id:goal.id config "second candidate" in
  let first, second = match ordered_tasks config [one; two] with
    | [first; second] -> first, second
    | [] | [_] | _ :: _ :: _ :: _ -> fail "expected two candidate rows" in
  let hook = Atomic.exchange Workspace_hooks.observe_task_transition_fn
      (fun _ ~agent_name:_ ~task_id ~transition ~details:_ ->
         if String.equal task_id first && transition = Masc_domain.Cancel then failwith "post-commit fixture") in
  let json = Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.observe_task_transition_fn hook)
      (fun () -> transition config goal.id "drop" |> success) in
  check (list string) "only the independent cancellation is reported as confirmed" [second]
    (drop_field json "cancelled" |> List.map Yojson.Safe.Util.to_string);
  check (list string) "post-commit error is reported" [first] (failed_task_ids json);
  (match failed_task_errors json with
   | [error] -> check bool "first commit may be unknown" true (contains ~sub:"commit status may be unknown" error)
   | [] | _ :: _ :: _ -> fail "expected one Task error");
  (match task_status config first with
   | Masc_domain.Cancelled _ -> ()
   | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
   | Masc_domain.AwaitingVerification _ | Masc_domain.Done _ -> fail "committed Task was not cancelled");
  (match task_status config second with
   | Masc_domain.Cancelled _ -> ()
   | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
   | Masc_domain.Done _ -> fail "independent Task was not cancelled")

let test_drop_refuses_duplicate_task_rows ~claimed () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  let id = add_task ~goal_id:goal.id config "duplicated candidate" in
  let independent = add_task ~goal_id:goal.id config "independent candidate" in
  if claimed then
    Masc.Workspace.transition_task_r config ~agent_name:"operator" ~task_id:id ~action:Masc_domain.Claim ()
    |> ok_or_fail;
  Workspace_utils.with_file_lock config (Workspace_backlog.backlog_lock_path config) (fun () ->
    let current = backlog config in
    let original = match List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id id) current.tasks with
      | Some task -> task | None -> fail "candidate missing" in
    let todo = { original with task_status = Masc_domain.Todo } in
    Workspace_backlog.write_backlog config { current with tasks = todo :: current.tasks });
  let duplicate_rows = (backlog config).tasks |> List.filter (fun (task : Masc_domain.task) -> String.equal task.id id) in
  let json = transition config goal.id "drop" |> success in
  check (list string) "duplicate Task is reported separately" [id] (failed_task_ids json);
  check (list string) "independent Task still cancels" [independent]
    (drop_field json "cancelled" |> List.map Yojson.Safe.Util.to_string);
  let held = drop_field json "held" |> List.map (fun row -> Yojson.Safe.Util.(
    to_string (member "task_id" row) ^ "/" ^ to_string (member "holder" row))) in
  if claimed then begin
    check (list string) "ambiguous held row remains observable" [id ^ "/operator"] held;
    (match (state config).pending_notifications with
     | [notice] ->
         check bool "holder notice names the ambiguous observation" true
           (contains ~sub:"stale or ambiguous" notice.content && contains ~sub:(id ^ " (operator)") notice.content)
     | _ -> fail "expected a durable ambiguous-holder notice")
  end else check (list string) "duplicate Todo rows have no holder" [] held;
  let after = (backlog config).tasks |> List.filter (fun (task : Masc_domain.task) -> String.equal task.id id) in
  check bool "neither duplicate Task row was rewritten" true
    (List.length duplicate_rows = List.length after && List.for_all2 Masc_domain.equal_task duplicate_rows after)

let test_drop_refuses_duplicate_linked_goal ~claimed () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  let other = match Goal_store.upsert_goal config ~title:"Possibly live" ~metric:"m" ~target_value:"1" () with
    | Ok (goal, _) -> goal | Error error -> fail (Goal_store.write_error_to_string error) in
  let id = add_task ~goal_id:goal.id config "possibly shared candidate" in
  let independent = add_task ~goal_id:goal.id config "independent candidate" in
  (match Workspace_goal_index.link_task_to_goal_result config ~goal_id:other.id ~task_id:id with
   | Ok _ -> () | Error _ -> fail "link the other Goal");
  if claimed then
    Masc.Workspace.transition_task_r config ~agent_name:"operator" ~task_id:id ~action:Masc_domain.Claim ()
    |> ok_or_fail;
  let current = state config in
  let duplicate = { other with phase = GP.Dropped } in
  (match Goal_store.write_state_result config { current with goals = duplicate :: current.goals } with
   | Ok () -> () | Error detail -> fail detail);
  let json = transition config goal.id "drop" |> success in
  check (list string) "ambiguous linked Goal is reported" [id] (failed_task_ids json);
  (match failed_task_errors json with
   | [error] -> check bool "linked Goal ambiguity is named" true (contains ~sub:"linked Goal ID is ambiguous" error)
   | [] | _ :: _ :: _ -> fail "expected one Task error");
  check (list string) "independent Task still cancels" [independent]
    (drop_field json "cancelled" |> List.map Yojson.Safe.Util.to_string);
  let held = drop_field json "held" |> List.map (fun row -> Yojson.Safe.Util.(
    to_string (member "task_id" row) ^ "/" ^ to_string (member "holder" row))) in
  if claimed then begin
    check (list string) "ambiguous linked Goal retains holder observation" [id ^ "/operator"] held;
    (match task_status config id with
     | Masc_domain.Claimed { assignee; _ } -> check string "holder preserved" "operator" assignee
     | Masc_domain.Todo | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
     | Masc_domain.Done _ | Masc_domain.Cancelled _ -> fail "held Task was changed")
  end else begin
    check (list string) "Todo candidate has no holder" [] held;
    (match task_status config id with
     | Masc_domain.Todo -> ()
     | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
     | Masc_domain.Done _ | Masc_domain.Cancelled _ -> fail "shared Task was changed")
  end

let test_drop_refuses_duplicate_target_goal ~claimed ~dropped_first () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  let id = add_task ~goal_id:goal.id config "candidate" in
  if claimed then
    Masc.Workspace.transition_task_r config ~agent_name:"operator" ~task_id:id ~action:Masc_domain.Claim ()
    |> ok_or_fail;
  let current = state config in
  let duplicate = { goal with title = "Different duplicate"; phase = GP.Dropped;
                              criterion_revision = "different-criterion" } in
  let rows = if dropped_first then [duplicate; goal] else [goal; duplicate] in
  (match Goal_store.write_state_result config { current with goals = rows } with
   | Ok () -> () | Error detail -> fail detail);
  let primary = Goal_store.goals_path config in
  let mirror = primary ^ ".last-good" in
  let before = Fs_compat.load_file primary, Fs_compat.load_file mirror in
  let abandoned = ref 0 in
  let hook = Atomic.exchange Workspace_hooks.goal_verification_abandoned_fn
      (fun _ ~goal_id:_ -> incr abandoned) in
  let result = Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.goal_verification_abandoned_fn hook)
      (fun () -> transition config goal.id "drop") in
  refused result;
  check bool "ambiguous target is named" true (contains ~sub:"goal ID has multiple rows" (Tool_result.message result));
  check string "ambiguous Goal primary unchanged" (fst before) (Fs_compat.load_file primary);
  check string "ambiguous Goal mirror unchanged" (snd before) (Fs_compat.load_file mirror);
  check int "ambiguous Goal does not abandon verification" 0 !abandoned;
  if claimed then begin
    (match task_status config id with
     | Masc_domain.Claimed { assignee; _ } -> check string "holder preserved" "operator" assignee
     | Masc_domain.Todo | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
     | Masc_domain.Done _ | Masc_domain.Cancelled _ -> fail "ambiguous target changed the held Task")
  end else begin
    (match task_status config id with
     | Masc_domain.Todo -> ()
     | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.AwaitingVerification _
     | Masc_domain.Done _ | Masc_domain.Cancelled _ -> fail "ambiguous target cancelled a Task")
  end

let test_drop_rejects_recovery_candidate ~links () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  ignore (add_task ~goal_id:goal.id config "candidate with recovery");
  let path = if links then Workspace_goal_index.goal_task_links_path config
    else Workspace_backlog.backlog_path config in
  let recovery = path ^ ".last-good" in
  check bool "valid recovery snapshot exists" true (Sys.file_exists recovery);
  save_atomic path "{broken";
  let json = transition config goal.id "drop" |> success in
  check bool "recovery cannot authorize cancellation" true
    Yojson.Safe.Util.(json |> member "tasks" |> member "unread" <> `Null);
  check string "corrupt primary was not rewritten" "{broken" (Fs_compat.load_file path);
  phase GP.Dropped (saved config goal.id)

let test_drop_without_reason_is_refused () = with_workspace @@ fun config _ ->
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal = create config in
  let todo = add_task ~goal_id:goal.id config "still wanted" in
  let ctx : Masc.Workspace_types.context = { config; agent_name = "operator" } in
  List.iter (fun (label, note) ->
      let result = Goals.handle_goal_transition ~tool_name:"masc_goal_transition"
          ~start_time:(Tool_timing.start ()) ctx
          (`Assoc (["goal_id", `String goal.id; "action", `String "drop"] @ note)) in
      refused result;
      check bool (label ^ " names the missing reason") true
        (let message = Tool_result.message result in
         let sub = "drop needs a note" in
         let n = String.length sub in
         let rec go i = i + n <= String.length message && (String.sub message i n = sub || go (i + 1)) in
         go 0);
      phase GP.Executing (saved config goal.id);
      (match task_status config todo with
       | Masc_domain.Todo -> ()
       | _ -> fail (label ^ " touched a linked Task")))
    [ "no note", []; "blank note", ["note", `String "   "] ]

let test_binding_unavailable_is_not_an_ended_request () = with_workspace @@ fun config _ ->
  let goal = create config in
  change config goal.id "request_complete";
  let request_id, _ = pending config goal.id in
  List.iter (fun path ->
    let original = Fs_compat.load_file path in
    let corrupt = "{unavailable" in
    Fun.protect ~finally:(fun () -> save_atomic path original)
      (fun () ->
        save_atomic path corrupt;
        (match Goal_verification.bind_review config ~goal_id:goal.id with
         | Error (Goal_verification.Binding_unavailable _) -> ()
         | Error (Goal_verification.No_current_review _) ->
           fail "unreadable authority was mistaken for an ended request"
         | Ok _ -> fail "unreadable authority admitted a review");
        check string "binding preserves unavailable bytes" corrupt (Fs_compat.load_file path));
    (match Goal_verification.bind_review config ~goal_id:goal.id with
     | Ok (_, (current, _, _)) -> check string "recovery binds the same request" request_id current
     | Error error -> fail (Goal_verification.review_binding_error_to_string error)))
    [Goal_store.goals_path config; Goal_verification.verifications_path config];
  change config goal.id "pause";
  (match Goal_verification.bind_review config ~goal_id:goal.id with
   | Error (Goal_verification.No_current_review _) -> ()
   | Error (Goal_verification.Binding_unavailable _) -> fail "confirmed suspension is not a read failure"
   | Ok _ -> fail "suspension admitted a new review");
  check string "suspension keeps the original pending proof" request_id (fst (pending config goal.id))

let () = run "Goal suspension" ["drop", [
  test_case "drop cancels leftover todo, keeps shared and held work" `Quick test_drop_cancels_left_over_todo;
  test_case "drop cancels multiple Tasks with independent guarded reads" `Quick test_drop_cancels_multiple_from_independent_reads;
  test_case "drop preserves a same-actor claim after its snapshot" `Quick test_drop_does_not_cancel_claim_after_snapshot;
  test_case "drop preserves a new handoff after claim and release" `Quick test_drop_preserves_new_handoff;
  test_case "drop refuses a claim between Task read and transition" `Quick test_drop_cas_refuses_claim_after_fresh_read;
  test_case "drop refuses a deleted then restored Task" `Quick test_drop_refuses_deleted_then_restored_task;
  test_case "drop continues after a post-commit Task error" `Quick test_drop_continues_after_post_commit_error;
  test_case "drop refuses duplicate Todo rows" `Quick (fun () -> test_drop_refuses_duplicate_task_rows ~claimed:false ());
  test_case "drop refuses duplicate Todo and Claimed rows" `Quick (fun () -> test_drop_refuses_duplicate_task_rows ~claimed:true ());
  test_case "drop refuses Todo linked to duplicate Goal rows" `Quick (fun () -> test_drop_refuses_duplicate_linked_goal ~claimed:false ());
  test_case "drop reports holder linked to duplicate Goal rows" `Quick (fun () -> test_drop_refuses_duplicate_linked_goal ~claimed:true ());
  test_case "drop refuses duplicate target before cancelling Todo" `Quick (fun () -> test_drop_refuses_duplicate_target_goal ~claimed:false ~dropped_first:false ());
  test_case "repeated drop refuses duplicate target and preserves holder" `Quick (fun () -> test_drop_refuses_duplicate_target_goal ~claimed:true ~dropped_first:true ());
  test_case "drop refuses backlog recovery as authority" `Quick (fun () -> test_drop_rejects_recovery_candidate ~links:false ());
  test_case "drop refuses link recovery as authority" `Quick (fun () -> test_drop_rejects_recovery_candidate ~links:true ());
  test_case "drop without a reason is refused and changes nothing" `Quick test_drop_without_reason_is_refused;
]; "contract", [
  test_case "transition refuses IDs that would be retargeted" `Quick
    test_transition_refuses_ids_that_would_be_retargeted;
  test_case "restore every live state across both suspension kinds" `Quick test_restore_matrix;
  test_case "terminal refusal and Drop/Reopen escape" `Quick test_terminal_and_escape;
  test_case "bound verdict preserves suspension and reconciles on restore" `Quick test_bound_result;
  test_case "unavailable binding preserves the pending request" `Quick test_binding_unavailable_is_not_an_ended_request;
  test_case "criterion edit invalidates proof but preserves suspension" `Quick test_edit_suspended;
  test_case "confirmation restores the same proof binding" `Quick test_confirmation_restores_binding;
  test_case "Candle failure retains pending proof and suspension" `Quick test_candle_failure;
  test_case "strict codec, distinct counts and filters" `Quick test_codec_and_rollup;
]]
