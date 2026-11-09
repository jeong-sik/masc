open Masc
module R = Goal_criterion_review
module Agent = Goal_criterion_agent
module AR = Task.Anti_rationalization
let get = function Ok value -> value | Error error -> Alcotest.fail (R.error_to_string error)
let tool config name fields =
  match Tool_workspace.dispatch {Tool_workspace.config; agent_name="planner"}
    ~name ~args:(`Assoc fields) with
  | Some result when Tool_result.is_success result -> Yojson.Safe.from_string (Tool_result.message result)
  | Some result -> Alcotest.fail (Tool_result.message result)
  | None -> Alcotest.fail ("unhandled tool " ^ name)
let create config =
  let json = tool config "masc_goal_upsert" ["title", `String "Measure real source units";
    "metric", `String "criterion-owner/source.txt"; "target_value", `String "100"] in
  Yojson.Safe.Util.(json |> member "goal_id" |> to_string)
let goal config goal_id = match Goal_store.find_goal config ~goal_id with
  | Goal_store.Goal_found goal -> goal
  | Goal_absent | Store_unavailable _ -> Alcotest.fail "Goal missing"
let current config goal_id = match R.current_for_goal (get (R.load config)) (goal config goal_id) with
  | Some record -> record | None -> Alcotest.fail "criterion request missing"
let state config goal_id =
  let json = tool config "masc_goal_list" [] in
  let goals = Yojson.Safe.Util.(json |> member "goals" |> to_list) in
  let selected = List.find (fun json -> Yojson.Safe.Util.(json |> member "id" |> to_string) = goal_id) goals in
  Yojson.Safe.Util.(selected |> member "criterion_review" |> member "state" |> to_string)
let with_workspace run =
  let directory = Filename.temp_dir "criterion-review-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs (); Fs_compat.remove_tree directory;
    Config_dir_resolver.reset ()) (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Time_compat.set_clock (Eio.Stdenv.clock env);
      Eio_context.set_clock (Eio.Stdenv.clock env);
      let config = Workspace.default_config directory in
      ignore (Workspace.init config ~agent_name:(Some "planner"));
      Prompt_registry.set_markdown_dir (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts");
      let root = Filename.concat (Workspace_verification_store.project_root_of_base_path directory)
        (Playground_paths.bundle_root "criterion-owner") in
      Fs_compat.mkdir_p root;
      Out_channel.with_open_bin (Filename.concat root "source.txt")
        (fun out -> output_string out "The measured subject exists; current value is 0.\n");
      run config env))
let with_reviewer reviewer run =
  let previous = Atomic.get AR.run_llm_reviewer_fn in
  let slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slots_fn in
  Fun.protect ~finally:(fun () -> Atomic.set AR.run_llm_reviewer_fn previous;
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn slots) (fun () ->
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
      (fun () -> Ok ["criterion-reviewer", Types_core.Catalog_slot]);
    Atomic.set AR.run_llm_reviewer_fn reviewer;
    run ())
let reviewer config goal_id calls before_reply answer =
  fun ~base_path ?sw:_ ?execution_owner:_ ~evaluator_runtime ~candidate_kind:_ ~prompt
      ?system_prompt ?goal_blocks:_ ~report_tool_schema:_ ~lookup ~on_tool_result
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;
    Alcotest.(check string) "actual workspace" config.Workspace.base_path base_path;
    (match (current config goal_id).phase with
     | R.Dispatching original ->
       Alcotest.(check string) "original prompt is durable before model" original.prompt prompt;
       Alcotest.(check (option string)) "original system message" (Some original.system_prompt) system_prompt
     | R.Pending _ | Judged _ | Reviewed _ | Deferred _ | Execution_unknown _ | Superseded _ ->
       Alcotest.fail "model called without durable dispatch intent");
    let input = `Assoc ["file_path", `String "criterion-owner/source.txt"] in
    let result = lookup.AR.dispatch ~name:"tool_read_file" ~args:input in
    Alcotest.(check bool) "real read-only lookup works" true (Tool_result.is_success result);
    on_tool_result ~input result;
    before_reply ();
    Ok {AR.selected_runtime_id=evaluator_runtime; evaluator_execution=None; verdict=answer}

let test_actual_intake_review_and_proof_separation () = with_workspace (fun config _ ->
  let goal_id = create config in
  Alcotest.(check string) "public creation is pending" "pending" (state config goal_id);
  let calls = ref 0 in
  with_reviewer (reviewer config goal_id calls (fun () -> ())
    (Some (AR.Approve "The subject exists and the declared measurement can reach the target."))) (fun () ->
    get (Agent.For_testing.process config ~goal_id);
    get (Agent.For_testing.recover config));
  Alcotest.(check int) "settled review is restored, never replayed" 1 !calls;
  Alcotest.(check string) "current criterion is viable" "viable" (state config goal_id);
  Alcotest.(check bool) "intake does not complete Goal" true ((goal config goal_id).phase = Goal_phase.Executing);
  (match Goal_verification.get_record_authoritative config ~goal_id with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> Alcotest.fail "intake impersonated completion proof");
  match (current config goal_id).phase with
  | R.Reviewed receipt -> Alcotest.(check int) "actual lookup retained" 1 (List.length receipt.tools)
  | R.Pending _ | Dispatching _ | Judged _ | Deferred _ | Execution_unknown _ | Superseded _ ->
    Alcotest.fail "review did not publish")

let test_needs_revision_is_not_goal_cancellation () = with_workspace (fun config _ ->
  let goal_id = create config in
  with_reviewer (reviewer config goal_id (ref 0) (fun () -> ())
    (Some (AR.Reject "The target does not specify comparable units; clarify it."))) (fun () ->
    get (Agent.For_testing.process config ~goal_id));
  Alcotest.(check string) "semantic refusal is visible" "needs_revision" (state config goal_id);
  Alcotest.(check bool) "Goal remains actor-owned" true ((goal config goal_id).phase = Goal_phase.Executing))

let test_non_verdict_and_explicit_retry () = with_workspace (fun config _ ->
  List.iter (fun answer ->
    let goal_id = create config in
    let calls = ref 0 in
    with_reviewer (reviewer config goal_id calls (fun () -> ()) answer) (fun () ->
      get (Agent.For_testing.process config ~goal_id);
      get (Agent.For_testing.recover config));
    Alcotest.(check string) "missing judgment stays deferred" "deferred" (state config goal_id);
    Alcotest.(check int) "ordinary recovery does not repeat a non-verdict" 1 !calls;
    let previous = current config goal_id in
    ignore (tool config "masc_goal_upsert" ["id", `String goal_id; "priority", `Int 2]);
    let retry = current config goal_id in
    Alcotest.(check (option string)) "explicit retry retains its parent" (Some previous.request_id) retry.supersedes;
    with_reviewer (reviewer config goal_id calls (fun () -> ()) (Some (AR.Approve "Clarified source is viable.")))
      (fun () -> get (Agent.For_testing.process config ~goal_id));
    Alcotest.(check int) "explicit actor action admits one successor" 2 !calls)
    [None; Some (AR.Approve "")])

let test_stale_verdict_cannot_approve_new_criterion () = with_workspace (fun config _ ->
  let goal_id = create config in
  let original = current config goal_id in
  let change () = ignore (tool config "masc_goal_upsert"
    ["id", `String goal_id; "target_value", `String "200"]) in
  with_reviewer (reviewer config goal_id (ref 0) change (Some (AR.Approve "Old target is viable.")))
    (fun () -> get (Agent.For_testing.process config ~goal_id));
  Alcotest.(check string) "replacement criterion still awaits review" "pending" (state config goal_id);
  match List.find (fun (record : R.record) -> record.request_id = original.request_id) (get (R.load config)) with
  | {phase=R.Superseded receipt; _} ->
    Alcotest.(check bool) "stale structured result remains durable" true (Option.is_some receipt.result.verdict)
  | {phase=(R.Pending _ | Dispatching _ | Judged _ | Reviewed _ | Deferred _ | Execution_unknown _); _} ->
    Alcotest.fail "stale judgment was not isolated")

let test_cancellation_retains_original_and_never_replays () = with_workspace (fun config _ ->
  let goal_id = create config in
  let original = current config goal_id in
  let calls = ref 0 in
  with_reviewer (reviewer config goal_id calls (fun () -> raise (Eio.Cancel.Cancelled Exit)) None) (fun () ->
    (try ignore (Agent.For_testing.process config ~goal_id); Alcotest.fail "cancellation swallowed"
     with Eio.Cancel.Cancelled _ -> ());
    get (Agent.For_testing.recover config);
    ignore (tool config "masc_goal_upsert" ["id", `String goal_id; "priority", `Int 2]);
    get (Agent.For_testing.process config ~goal_id));
  Alcotest.(check int) "cancelled dispatch is never replayed" 1 !calls;
  Alcotest.(check string) "original identity survives" original.request_id (current config goal_id).request_id;
  match (current config goal_id).phase with
  | R.Execution_unknown {tools; _} -> Alcotest.(check int) "actual prior lookup survives" 1 (List.length tools)
  | R.Pending _ | Dispatching _ | Judged _ | Reviewed _ | Deferred _ | Superseded _ ->
    Alcotest.fail "uncertain original was lost")

let test_unknown_provider_dispatch_does_not_fall_back_or_replay () = with_workspace (fun config _ ->
  let goal_id = create config in
  let calls = ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation ~on_runtime_attempt_error () ->
    incr calls;
    let error = Agent_core.Error.Api (Agent_core.Error.Retry.NetworkError
      {message="criterion reply lost"; kind=Llm_provider.Http_client.Connection_reset}) in
    Alcotest.(check bool) "retained original owns uncertain continuation" true
      (attempt_continuation ~dispatch:Runtime_attempt_dispatch.Dispatched error = Runtime_attempt_dispatch.Original_must_resolve);
    on_runtime_attempt_error ~runtime_id:evaluator_runtime ~attempt:0 ~dispatch:Runtime_attempt_dispatch.Dispatched error;
    Error error) (fun () ->
      Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn (fun () -> Ok
        ["criterion-reviewer", Types_core.Catalog_slot; "must-not-run", Types_core.Catalog_slot]);
      ignore (Agent.For_testing.process config ~goal_id);
      get (Agent.For_testing.recover config));
  Alcotest.(check int) "unknown execution neither falls back nor replays" 1 !calls;
  Alcotest.(check string) "unknown is explicit" "execution_unknown" (state config goal_id))

let test_observed_reply_survives_one_retention_failure () = with_workspace (fun config _ ->
  let goal_id = create config in
  let calls = ref 0 in
  let directory = Filename.dirname (R.path config) in
  let original_mode = (Unix.stat directory).Unix.st_perm in
  let refuse_write () = Unix.chmod directory 0o500 in
  Fun.protect ~finally:(fun () -> Unix.chmod directory original_mode) (fun () ->
    with_reviewer (reviewer config goal_id calls refuse_write
      (Some (AR.Approve "This exact observed reply remains viable after storage recovers."))) (fun () ->
      match Agent.For_testing.process config ~goal_id with
      | Error (R.Store_unavailable _) -> ()
      | Ok () | Error (R.Goal_unavailable _ | R.Conflict _) ->
        Alcotest.fail "fixture did not refuse the reply persistence"));
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () -> Alcotest.fail "observed reply replayed")
    (fun () -> get (Agent.For_testing.recover config));
  Alcotest.(check int) "provider called once despite persistence refusal" 1 !calls;
  Alcotest.(check string) "same observed reply publishes after recovery" "viable" (state config goal_id);
  match (current config goal_id).phase with
  | R.Reviewed receipt ->
    Alcotest.(check int) "same actual lookup is retained" 1 (List.length receipt.tools);
    (match receipt.result.verdict with
     | Some (AR.Approve reason) -> Alcotest.(check string) "same model reason survives"
         "This exact observed reply remains viable after storage recovers." reason
     | Some (AR.Reject _) | None -> Alcotest.fail "known reply was replaced")
  | R.Pending _ | Dispatching _ | Judged _ | Deferred _ | Execution_unknown _ | Superseded _ ->
    Alcotest.fail "known reply was lost")

let test_unreadable_ledger_is_not_unchecked () = with_workspace (fun config _ ->
  let goal_id = create config in
  Out_channel.with_open_bin (R.path config) (fun out -> output_string out "{broken");
  (match Agent.For_testing.process config ~goal_id with
   | Error (R.Store_unavailable _) -> ()
   | Ok () | Error (R.Goal_unavailable _ | R.Conflict _) -> Alcotest.fail "corrupt ledger granted authority");
  Alcotest.(check string) "unreadable assessment is visible" "unavailable" (state config goal_id);
  Alcotest.(check string) "broken bytes preserved" "{broken"
    (In_channel.with_open_bin (R.path config) In_channel.input_all))

let test_missing_primary_cannot_replay_a_dispatched_original () = with_workspace (fun config _ ->
  let goal_id = create config in
  let calls = ref 0 in
  with_reviewer (reviewer config goal_id calls (fun () -> raise (Eio.Cancel.Cancelled Exit)) None) (fun () ->
    (try ignore (Agent.For_testing.process config ~goal_id) with Eio.Cancel.Cancelled _ -> ());
    Sys.remove (R.path config);
    (match Agent.For_testing.process config ~goal_id with
     | Error (R.Store_unavailable _) -> ()
     | Ok () | Error (R.Goal_unavailable _ | R.Conflict _) -> Alcotest.fail "missing original became a fresh request"));
  Alcotest.(check int) "lost primary cannot replay a provider effect" 1 !calls;
  Alcotest.(check string) "mirror is evidence of unavailability, never authority" "unavailable" (state config goal_id))

let test_actual_goal_list_observation_fits_descriptor_output () = with_workspace (fun config _ ->
  let goal_id = create config in
  with_reviewer (reviewer config goal_id (ref 0) (fun () -> ())
    (Some (AR.Reject "The target needs concrete comparable units."))) (fun () ->
      get (Agent.For_testing.process config ~goal_id));
  let module D = Keeper_tool_descriptor in
  let module P = Keeper_tool_plan in
  let descriptor = List.find (fun (descriptor : D.t) -> descriptor.internal_name = "masc_goal_list")
    (D.all_descriptors ()) in
  let public_name = match D.keeper_model_names descriptor with
    | first :: _ -> first | [] -> Alcotest.fail "Goal list has no descriptor name" in
  let node_id = match P.Node_id.make "goals" with
    | Ok id -> id | Error P.Node_id.Empty -> Alcotest.fail "invalid fixture node" in
  let node = P.node ~id:node_id ~tool_name:public_name
    ~input:(P.Json_template.literal (`Assoc [])) () in
  let plan = match P.create ~descriptors:(D.all_descriptors ()) [node] with
    | Ok plan -> plan | Error _ -> Alcotest.fail "Goal observation plan rejected" in
  match P.validate_output plan ~run_id:(P.Run_id.fresh ()) ~node_id (tool config "masc_goal_list" []) with
  | Ok _ -> () | Error _ -> Alcotest.fail "B2 observation broke the declared Goal output contract")

let test_started_agent_consumes_public_upsert_wake () = with_workspace (fun config env ->
  let called, resolve = Eio.Promise.create () in
  let calls = ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;
    let id = match get (R.load config) with
      | [record] -> record.R.goal_id
      | [] | _ :: _ -> Alcotest.fail "startup did not retain exactly its public request" in
    (match (current config id).phase with R.Dispatching _ -> ()
     | R.Pending _ | Judged _ | Reviewed _ | Deferred _ | Execution_unknown _ | Superseded _ ->
       Alcotest.fail "startup model has no durable owner");
    Eio.Promise.resolve resolve ();
    Ok {AR.selected_runtime_id=evaluator_runtime; evaluator_execution=None;
      verdict=Some (AR.Approve "The declared subject and path exist.")}) (fun () ->
      Eio.Switch.run (fun sw ->
        Agent.start ~sw ~clock:(Eio.Stdenv.clock env) ~config;
        Eio.Fiber.yield ();
        ignore (create config);
        Eio.Promise.await called));
  Alcotest.(check int) "installed daemon consumes the public wake" 1 !calls)

let test_started_agent_reconciles_interrupted_dispatch () = with_workspace (fun config env ->
  let goal_id = create config in
  let requested = current config goal_id in
  let original : R.original = {prompt="Retained original criterion";
    system_prompt="Read-only criterion review"; lookup_binding=String.make 64 '0'} in
  ignore (get (R.begin_dispatch config requested original));
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () -> Alcotest.fail "orphan dispatch replayed") (fun () ->
    Eio.Switch.run (fun sw ->
      Agent.start ~sw ~clock:(Eio.Stdenv.clock env) ~config;
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10. (fun () ->
        let rec await_unknown () =
          if state config goal_id <> "execution_unknown" then (Eio.Fiber.yield (); await_unknown ()) in
        await_unknown ());
      Alcotest.(check string) "restart withdraws a false running observation" "execution_unknown" (state config goal_id);
      Eio.Fiber.yield ()));
  match (current config goal_id).phase with
  | R.Execution_unknown saved ->
    Alcotest.(check string) "original request retained" requested.request_id (current config goal_id).request_id;
    Alcotest.(check string) "original prompt retained" original.prompt saved.original.prompt
  | R.Pending _ | Dispatching _ | Judged _ | Reviewed _ | Deferred _ | Superseded _ ->
    Alcotest.fail "restart lost the uncertain original")

(* Rewind only the publication marker of an actual model receipt to the
   durable state immediately after retain_reply. No fabricated verdict is
   used to exercise boot recovery across later Goal mutations. *)
let retain_unpublished_fixture config goal_id =
  let request_id = (current config goal_id).request_id in
  let json = In_channel.with_open_bin (R.path config) In_channel.input_all |> Yojson.Safe.from_string in
  let field key value fields = List.map (fun (name, old) -> name, if name=key then value else old) fields in
  let json = match json with
    | `Assoc fields ->
      let records = Yojson.Safe.Util.(List.assoc "records" fields |> to_list) in
      let records = List.map (function
        | `Assoc row when List.assoc "request_id" row = `String request_id ->
          let phase = match List.assoc "phase" row with
            | `Assoc phase -> `Assoc (field "state" (`String "judged") phase)
            | _ -> Alcotest.fail "actual receipt phase missing" in
          `Assoc (field "phase" phase row)
        | row -> row) records in
      `Assoc (field "records" (`List records) fields)
    | _ -> Alcotest.fail "actual ledger missing" in
  Out_channel.with_open_bin (R.path config) (fun out -> output_string out (Yojson.Safe.to_string json));
  request_id

let test_retained_judgments_recover_after_goal_mutation () = with_workspace (fun config _ ->
  List.iter (fun replacement ->
    let goal_id = create config in
    with_reviewer (reviewer config goal_id (ref 0) (fun () -> ())
      (Some (AR.Approve "The declared source and target are coherent."))) (fun () ->
        get (Agent.For_testing.process config ~goal_id));
    let request_id = retain_unpublished_fixture config goal_id in
    if replacement then ignore (tool config "masc_goal_upsert"
      ["id", `String goal_id; "target_value", `String "200"]);
    ignore (Goal_store.transact_goal config ~goal_id (fun goal ->
      Ok ({goal with phase=Goal_phase.Paused Goal_phase.Resume_executing}, ())));
    get (Agent.For_testing.recover config);
    let saved = List.find (fun (record : R.record) -> record.request_id=request_id) (get (R.load config)) in
    match replacement, saved.phase with
    | true, R.Superseded _ | false, R.Reviewed _ -> ()
    | _, (R.Pending _ | Dispatching _ | Judged _ | Reviewed _ | Deferred _ | Execution_unknown _ | Superseded _) ->
      Alcotest.fail "retained reply was stranded behind Goal admission") [false; true])

let test_one_waiting_provider_does_not_block_other_goals () = with_workspace (fun config env ->
  let first, first_ready = Eio.Promise.create () in
  let second, second_ready = Eio.Promise.create () in
  let released, release = Eio.Promise.create () in
  let calls = ref 0 in
  with_reviewer (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime ~candidate_kind:_ ~prompt:_
      ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
      ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
    incr calls;
    if !calls = 1 then (Eio.Promise.resolve first_ready (); Eio.Promise.await released)
    else Eio.Promise.resolve second_ready ();
    Ok {AR.selected_runtime_id=evaluator_runtime; evaluator_execution=None;
      verdict=Some (AR.Approve "Declared source and target are coherent.")}) (fun () ->
      Eio.Switch.run (fun sw ->
        Agent.start ~sw ~clock:(Eio.Stdenv.clock env) ~config;
        ignore (create config);
        Eio.Promise.await first;
        Agent.start ~sw ~clock:(Eio.Stdenv.clock env) ~config;
        Alcotest.(check bool) "duplicate start preserves the live dispatch" true
          (List.exists (fun (record : R.record) -> match record.phase with
            | R.Dispatching _ -> true
            | Pending _ | Judged _ | Reviewed _ | Deferred _ | Execution_unknown _ | Superseded _ -> false)
            (get (R.load config)));
        ignore (create config);
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10. (fun () -> Eio.Promise.await second);
        Eio.Promise.resolve release ()));
  Alcotest.(check int) "both independent criteria entered the real reviewer" 2 !calls)

let () = Alcotest.run "Goal criterion review" ["behavior", [
  Alcotest.test_case "actual intake, lookup, durable judgment and proof separation" `Quick test_actual_intake_review_and_proof_separation;
  Alcotest.test_case "semantic refusal preserves Goal lifecycle" `Quick test_needs_revision_is_not_goal_cancellation;
  Alcotest.test_case "non-verdict requires explicit retry" `Quick test_non_verdict_and_explicit_retry;
  Alcotest.test_case "criterion revision fences stale model judgment" `Quick test_stale_verdict_cannot_approve_new_criterion;
  Alcotest.test_case "cancelled execution retains its owner and lookup" `Quick test_cancellation_retains_original_and_never_replays;
  Alcotest.test_case "unknown provider effect cannot fall back or replay" `Quick test_unknown_provider_dispatch_does_not_fall_back_or_replay;
  Alcotest.test_case "observed reply survives persistence refusal without replay" `Quick test_observed_reply_survives_one_retention_failure;
  Alcotest.test_case "unreadable ledger remains unavailable" `Quick test_unreadable_ledger_is_not_unchecked;
  Alcotest.test_case "missing primary never resets an uncertain original" `Quick test_missing_primary_cannot_replay_a_dispatched_original;
  Alcotest.test_case "actual observation fits the descriptor output" `Quick test_actual_goal_list_observation_fits_descriptor_output;
  Alcotest.test_case "started application lane consumes public upsert" `Quick test_started_agent_consumes_public_upsert_wake;
  Alcotest.test_case "new lane preserves interrupted original as unknown" `Quick test_started_agent_reconciles_interrupted_dispatch;
  Alcotest.test_case "retained replies recover after Goal mutation" `Quick test_retained_judgments_recover_after_goal_mutation;
  Alcotest.test_case "one provider wait does not block another Goal" `Quick test_one_waiting_provider_does_not_block_other_goals
]]
