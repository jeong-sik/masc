open Alcotest
module S = Keeper_repetition_snapshot
module Runtime = Masc.Keeper_repetition_scope

let require label = function
  | Ok value -> value
  | Error _ -> fail (label ^ " unexpectedly failed")

let id value =
  Keeper_execution_scope_id.of_json (`Assoc [ "kind", `String "direct_operation"; "id", `String value ])
  |> require "scope ID"

let hash text = Digestif.SHA256.(digest_string text |> to_hex)

let call : Masc.Keeper_agent_result.tool_call_detail =
  { tool_name = "Execute"; provider = "fixture"; execution_outcome = Tool_result.Ok
  ; typed_outcome = None; latency_ms = 1.; task_id = None; route_evidence = None
  ; input_fingerprint = Some (hash "same-input")
  ; output_fingerprint = Some (hash "same-output") }

let record state scope call =
  let observation = Runtime.observation_of_call call |> require "observation" in
  S.record state ~scope observation |> require "record"

let count state scope =
  Runtime.tool_calls state ~scope |> require "scope observations" |> List.length

let detector state scope =
  Runtime.tool_calls state ~scope |> require "scope observations"
  |> Masc.Keeper_agent_run.For_testing.repeated_exact_tool_call ~threshold:3

let checkpoint_restore state =
  let context = Masc.Keeper_context_core.create ~eio:false ~system_prompt:"scope test" in
  let checkpoint = Masc.Keeper_context_core.checkpoint_of_context context in
  let checkpoint = { checkpoint with Agent_core.Checkpoint.session_id = "scope-session"
    ; agent_name = "scope-owner"; model = "scope-model" } in
  Runtime.save checkpoint.context state;
  let restored = Agent_core.Checkpoint.to_string checkpoint
    |> Agent_core.Checkpoint.of_string |> require "actual checkpoint codec" in
  let target = Agent_core.Context.create_sync () in
  Agent_core.Context.set target "unrelated" (`String "keep");
  let state = Runtime.restore ~source:restored.context ~target |> require "explicit runtime restore" in
  check bool "unrelated target value retained" true
    (Agent_core.Context.get target "unrelated" = Some (`String "keep"));
  check bool "runtime projection restored" true
    (S.to_json state = S.to_json (Runtime.load target |> require "load runtime"));
  state

let test_a_b_restart_a () =
  let a = id "operation-a" and b = id "operation-b" in
  let state = S.admit S.empty (S.Fresh a) |> require "admit A" in
  let state = record (record state a call) a call in
  let state = S.admit state (S.Fresh b) |> require "admit B" in
  let state = record state b call in
  check (option (pair string int)) "new B does not inherit A" None (detector state b);
  let state = checkpoint_restore state in
  let state = S.admit state (S.Resume a) |> require "resume A" in
  let state = record state a call in
  check (option (pair string int)) "resumed A reaches its own threshold"
    (Some ("Execute", 3)) (detector state a);
  check int "B remains isolated" 1 (count state b);
  Runtime.tool_calls state ~scope:a |> require "restored evidence"
  |> List.iter (fun evidence ->
    check bool "history does not fabricate successful execution" true
      (evidence.Masc.Keeper_agent_result.execution_outcome = Tool_result.Unknown))

let test_same_fresh_and_two_plus_two () =
  let a = id "duplicate-operation" in
  let state = S.admit S.empty (S.Fresh a) |> require "admit" in
  let state = record (record state a call) a call |> checkpoint_restore in
  let state = S.admit state (S.Fresh a) |> require "duplicate admission" in
  check int "same Fresh preserves previous evidence" 2 (count state a);
  let state = record (record state a call) a call in
  check (option (pair string int)) "attempt split2+2 does not reset"
    (Some ("Execute", 4)) (detector state a)

let test_unknown_resume_and_record () =
  let missing = id "missing-operation" in
  (match S.admit S.empty (S.Resume missing) with
   | Error (S.Unknown_scope found) -> check bool "exact missing identity" true (Keeper_execution_scope_id.equal found missing)
   | _ -> fail "unknown Resume became Fresh");
  let observation = Runtime.observation_of_call call |> require "observation" in
  match S.record S.empty ~scope:missing observation with
  | Error (S.Unknown_scope _) -> ()
  | _ -> fail "observation invented admission"

let test_observations_are_valid_before_save () =
  List.iter (fun invalid ->
    match Runtime.observation_of_call invalid with
    | Error (S.Invalid_observation _) -> ()
    | _ -> fail "invalid observation was recordable")
    [ {call with tool_name = " "}; {call with input_fingerprint = Some "invalid"}
    ; {call with output_fingerprint = Some "invalid"} ];
  let a = id "canonical-fingerprints" in
  let upper = {call with input_fingerprint = Option.map String.uppercase_ascii call.input_fingerprint} in
  let state = S.admit S.empty (S.Fresh a) |> require "admit" in
  let state = record state a upper in
  check bool "constructor and decoder agree"
    true (S.to_json state = S.to_json (checkpoint_restore state));
  let state = record (record state a call) a call in
  check (option (pair string int)) "canonical fingerprints compare before and after restore"
    (Some ("Execute", 3)) (detector state a)

let test_invalid_snapshot_does_not_clear_target () =
  let a = id "retained-operation" in
  let valid = S.admit S.empty (S.Fresh a) |> require "admit" in
  let valid = record valid a call in
  let source = Agent_core.Context.create_sync () in
  let target = Agent_core.Context.create_sync () in
  Runtime.save target valid;
  Agent_core.Context.set_scoped source Agent_core.Context.Session "keeper_repetition_scopes"
    (`Assoc [ "schema", `String "unsupported" ]);
  (match Runtime.restore ~source ~target with
   | Error (S.Invalid_snapshot _) -> ()
   | _ -> fail "corrupt checkpoint reset scope state");
  check int "target retained on decode failure" 1 (count (Runtime.load target |> require "target") a);
  let fields = match S.to_json valid with `Assoc fields -> fields | _ -> fail "object expected" in
  let rows = Yojson.Safe.Util.(S.to_json valid |> member "scopes" |> to_list) in
  let replace name value = `Assoc ((name, value) :: List.remove_assoc name fields) in
  let invalids =
    [ `Assoc (("schema", `String "duplicate") :: fields)
    ; replace "scopes" (`List (rows @ rows))
    ; replace "active" (Keeper_execution_scope_id.to_json (id "unknown-active"))
    ; `Assoc (("unexpected", `Null) :: fields) ] in
  List.iter (fun json -> match S.of_json json with
    | Error (S.Invalid_snapshot _) -> ()
    | _ -> fail "invalid scope checkpoint accepted") invalids

let test_restore_does_not_replace_runtime_evidence () =
  let a = id "restore-conflict" in
  let initial = S.admit S.empty (S.Fresh a) |> require "admit" in
  let older = record (record initial a call) a call in
  let newer = record older a call in
  let source = Agent_core.Context.create_sync () in
  let target = Agent_core.Context.create_sync () in
  Runtime.save target newer;
  let assert_conflict label =
    (match Runtime.restore ~source ~target with
     | Error S.Restore_target_conflict -> ()
     | _ -> fail (label ^ " erased runtime evidence"));
    check int (label ^ " preserves observations") 3
      (count (Runtime.load target |> require "target after conflict") a) in
  assert_conflict "absent source";
  Runtime.save source older;
  assert_conflict "older checkpoint";
  Runtime.save source newer;
  let same = Runtime.restore ~source ~target |> require "same checkpoint replay" in
  check int "identical restore is idempotent" 3 (count same a);
  let corrupt = `Assoc ["schema", `String "corrupt-target"] in
  Agent_core.Context.set_scoped target Agent_core.Context.Session "keeper_repetition_scopes" corrupt;
  (match Runtime.restore ~source ~target with
   | Error (S.Invalid_snapshot _) -> ()
   | _ -> fail "corrupt target was overwritten");
  check bool "corrupt target evidence remains" true
    (Agent_core.Context.get_scoped target Agent_core.Context.Session "keeper_repetition_scopes"
     = Some corrupt)

let operation value =
  Keeper_chat_operation.Operation_id.of_string value |> require "operation"

let test_direct_retry_without_provider_checkpoint () =
  let source = Agent_core.Context.create_sync () in
  let target = Agent_core.Context.create_sync () in
  let execution = Runtime.Execution.direct_operation (operation "direct-a") in
  let prepare target = Runtime.Execution.prepare execution ~source ~target |> require "attempt" in
  check int "fresh direct operation excludes prior session calls" 0 (List.length (prepare target));
  Runtime.Execution.observe execution ~target call;
  Runtime.Execution.observe execution ~target call;
  (* The provider returned no checkpoint. Its observations still belong to
     this admitted operation when the direct cascade starts another attempt. *)
  let retry_target = Agent_core.Context.create_sync () in
  let prior_calls = prepare retry_target in
  check int "same admitted operation retains two observations" 2 (List.length prior_calls);
  Runtime.Execution.observe execution ~target:retry_target call;
  check bool "existing detector catches third call across attempts" true
    (Option.is_some
       (Masc.Keeper_agent_run.For_testing.repeated_exact_tool_call
          ~threshold:3 (call :: prior_calls)));
  let restored = Runtime.load retry_target |> require "projected checkpoint" |> checkpoint_restore in
  check int "tool-boundary checkpoint contains all three observations" 3
    (count restored (id "direct-a"));
  let next_source = Agent_core.Context.create_sync () in
  Runtime.save next_source restored;
  let next_target = Agent_core.Context.create_sync () in
  let next = Runtime.Execution.direct_operation (operation "direct-b") in
  let next_calls = Runtime.Execution.prepare next ~source:next_source ~target:next_target
    |> require "new direct operation" in
  check int "B does not inherit A's repeats" 0 (List.length next_calls);
  Runtime.Execution.observe next ~target:next_target call;
  let next_snapshot = Runtime.load next_target |> require "B projection" in
  check int "A evidence is preserved" 3 (count next_snapshot (id "direct-a"));
  check int "B evidence belongs only to B" 1 (count next_snapshot (id "direct-b"))

let test_direct_observation_failure_is_latched () =
  let source = Agent_core.Context.create_sync () in
  let target = Agent_core.Context.create_sync () in
  let execution = Runtime.Execution.direct_operation (operation "direct-invalid") in
  ignore (Runtime.Execution.prepare execution ~source ~target |> require "prepare");
  Runtime.Execution.observe execution ~target call;
  let valid = Runtime.load target |> require "valid projection" |> S.to_json in
  Runtime.Execution.observe execution ~target { call with input_fingerprint = Some "invalid" };
  check bool "failure is visible to provider boundary" true
    (Option.is_some (Runtime.Execution.failure execution));
  Runtime.Execution.observe execution ~target call;
  check bool "later callback does not hide failure" true
    (Option.is_some (Runtime.Execution.failure execution));
  check bool "valid checkpoint observations remain intact" true
    (valid = (Runtime.load target |> require "retained projection" |> S.to_json));
  let retry_target = Agent_core.Context.create_sync () in
  check bool "provider retry cannot reset failed observation state" true
    (Result.is_error (Runtime.Execution.prepare execution ~source ~target:retry_target))

let test_direct_prepare_preserves_conflicting_target () =
  let source = Agent_core.Context.create_sync () in
  let target = Agent_core.Context.create_sync () in
  let other = S.admit S.empty (S.Fresh (id "other-direct")) |> require "other scope" in
  Runtime.save target other;
  let execution = Runtime.Execution.direct_operation (operation "direct-target") in
  (match Runtime.Execution.prepare execution ~source ~target with
   | Error S.Restore_target_conflict -> ()
   | _ -> fail "unrelated runtime context was replaced");
  check bool "conflicting target is unchanged" true
    (S.to_json other = (Runtime.load target |> require "target" |> S.to_json))

let test_failed_scope_stops_official_provider_preparation () =
  let source = Agent_core.Context.create_sync () in
  let target = Agent_core.Context.create_sync () in
  let execution = Runtime.Execution.direct_operation (operation "direct-host-failure") in
  ignore (Runtime.Execution.prepare execution ~source ~target |> require "prepare");
  Runtime.Execution.observe execution ~target { call with output_fingerprint = Some "invalid" };
  let inner_called = ref false and projected = ref false in
  let hooks =
    { Agent_core.Hooks.empty with
      before_turn_params = Some
        (Masc.Keeper_run_tools_hooks.guard_repetition_before_turn_params
           (Some execution)
           (fun _ -> inner_called := true; Agent_core.Hooks.Continue)) }
  in
  let result = Masc.Keeper_official_client_host.prepare_turn
      ~runtime_label:"scope-test" ~keeper_name:"scope-owner" ~turn_count:1
      ~system_prompt:"system" ~tools:[] ~initial_messages:[]
      ~model_input_projection:(Some (fun messages -> projected := true; Ok messages))
      ~hooks:(Some hooks) ~configured_reasoning_effort:None
  in
  (match result with
   | Error (Agent_core.Error.Internal _) -> ()
   | _ -> fail "official provider preparation did not propagate scope hook failure");
  check bool "failed scope does not enter later preparation hook" false !inner_called;
  check bool "failed scope does not project a provider request" false !projected

let test_native_terminal_evidence_precedes_scope_failure () =
  let source = Agent_core.Context.create_sync () in
  let target = Agent_core.Context.create_sync () in
  let execution = Runtime.Execution.direct_operation (operation "direct-terminal") in
  ignore (Runtime.Execution.prepare execution ~source ~target |> require "prepare");
  Runtime.Execution.observe execution ~target { call with output_fingerprint = Some "invalid" };
  let decide = Masc.Keeper_agent_run.For_testing.tool_boundary_before_repetition
      ~repetition_execution:(Some execution) in
  let completed = Masc.Keeper_tools_agent_core.Terminal_effect_completed
      (Masc.Keeper_tool_execution.Memory_write_completed { revision = 1 }) in
  (match decide completed with
   | Ok (Runtime_agent.Yield Runtime_agent.Terminal_tool_completed) -> ()
   | _ -> fail "scope failure hid an exact completed effect");
  let failed = Masc.Keeper_tools_agent_core.Terminal_effect_failed
      { failure_class = Tool_result.Runtime_failure
      ; effect_disposition = Tool_result.Proven_post_effect
      ; diagnostic = "exact committed failure" } in
  check bool "structured terminal failure stays exact" true
    (decide failed = Masc.Keeper_agent_run.terminal_effect_boundary_decision failed);
  (match decide Masc.Keeper_tools_agent_core.Terminal_effect_open with
   | Error (Agent_core.Error.Internal _) -> ()
   | _ -> fail "open boundary continued despite latched scope failure")

let test_shared_identity_and_snapshot_codec () =
  let canonical = Keeper_operation_id.of_string "canonical-operation" |> require "leaf ID" in
  (* These annotations require public type equality, not a string roundtrip. *)
  let journal : Keeper_chat_operation.Operation_id.t = canonical in
  let leaf : Keeper_operation_id.t = journal in
  check bool "journal and scope share the same validated scalar" true
    (Keeper_operation_id.equal canonical leaf);
  let a = Keeper_execution_scope_id.direct_operation journal in
  let uuid = Uuidm.of_string "812f3e8b-df18-48e1-bd6e-0c6f4e6dd174"
    |> Option.get in
  let b = Keeper_execution_scope_id.autonomous_admission uuid in
  let observation = S.observation ~tool_name:"Execute"
      ~input_fingerprint:(Some (String.uppercase_ascii (hash "same-input")))
      ~output_fingerprint:None |> require "pure observation" in
  let first = S.admit S.empty (S.Fresh a) |> require "A" in
  let first = S.record first ~scope:a observation |> require "record A" in
  let first = S.admit first (S.Fresh b) |> require "B" in
  let reversed = S.admit S.empty (S.Fresh b) |> require "reverse B" in
  let reversed = S.admit reversed (S.Fresh a) |> require "reverse A" in
  let reversed = S.record reversed ~scope:a observation |> require "reverse record A" in
  let reversed = S.admit reversed (S.Resume b) |> require "reverse active B" in
  check bool "equal ignores map insertion order" true (S.equal first reversed);
  check bool "scope membership includes empty admitted frame" true
    (List.equal Keeper_execution_scope_id.equal [a; b] (S.scope_ids first));
  let expected = `Assoc
    [ "schema", `String "masc.keeper_repetition_scopes.v1"
    ; "active", Keeper_execution_scope_id.to_json b
    ; "scopes", `List
        [ `Assoc [ "id", Keeper_execution_scope_id.to_json a
                 ; "observations", `List
                     [ `Assoc [ "tool_name", `String "Execute"
                              ; "input_fingerprint", `String (hash "same-input")
                              ; "output_fingerprint", `Null ] ] ]
        ; `Assoc [ "id", Keeper_execution_scope_id.to_json b
                 ; "observations", `List [] ] ] ] in
  check string "canonical v1 bytes retain both evidence and empty scope"
    (Yojson.Safe.to_string expected) (Yojson.Safe.to_string (S.to_json first));
  let decoded = Yojson.Safe.to_string expected |> Yojson.Safe.from_string
    |> S.of_json |> require "pure snapshot wire roundtrip" in
  check bool "pure journal codec equals runtime projection" true (S.equal first decoded);
  let resumed_a = S.admit decoded (S.Resume a) |> require "select A" in
  check bool "active identity is part of equality" false (S.equal first resumed_a);
  let twice = S.record decoded ~scope:a observation |> require "second observation" in
  check bool "observation multiplicity is part of equality" false (S.equal first twice);
  check bool "missing empty frame is not equivalent to admitted empty frame" false
    (S.equal S.empty (S.admit S.empty (S.Fresh b) |> require "empty B"))

let () =
  run "keeper repetition scope checkpoint"
    [ "scope", [ test_case "shared identity and canonical pure snapshot" `Quick test_shared_identity_and_snapshot_codec
               ; test_case "A B checkpoint restart A" `Quick test_a_b_restart_a
               ; test_case "idempotent Fresh and2+2" `Quick test_same_fresh_and_two_plus_two
               ; test_case "unknown Resume and record" `Quick test_unknown_resume_and_record
               ; test_case "valid observations before save" `Quick test_observations_are_valid_before_save
               ; test_case "invalid checkpoint preserves target" `Quick test_invalid_snapshot_does_not_clear_target
               ; test_case "restore cannot replace runtime evidence" `Quick test_restore_does_not_replace_runtime_evidence
               ; test_case "direct retry without checkpoint then new operation" `Quick test_direct_retry_without_provider_checkpoint
               ; test_case "direct observation failure survives retry" `Quick test_direct_observation_failure_is_latched
               ; test_case "direct preparation retains conflicting target" `Quick test_direct_prepare_preserves_conflicting_target
               ; test_case "failed scope stops actual official preparation" `Quick test_failed_scope_stops_official_provider_preparation
               ; test_case "native terminal evidence precedes scope failure" `Quick test_native_terminal_evidence_precedes_scope_failure ] ]
