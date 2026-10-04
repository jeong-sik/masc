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
    (`Assoc ["goal_id", `String id; "action", `String action])
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
      change config goal.id first;
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
       | Error error -> fail error);
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

let () = run "Goal suspension" ["contract", [
  test_case "restore every live state across both suspension kinds" `Quick test_restore_matrix;
  test_case "terminal refusal and Drop/Reopen escape" `Quick test_terminal_and_escape;
  test_case "bound verdict preserves suspension and reconciles on restore" `Quick test_bound_result;
  test_case "criterion edit invalidates proof but preserves suspension" `Quick test_edit_suspended;
  test_case "confirmation restores the same proof binding" `Quick test_confirmation_restores_binding;
  test_case "Candle failure retains pending proof and suspension" `Quick test_candle_failure;
  test_case "strict codec, distinct counts and filters" `Quick test_codec_and_rollup;
]]
