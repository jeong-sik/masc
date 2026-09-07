open Alcotest
module S = Masc.Keeper_repetition_scope

let require label = function
  | Ok value -> value
  | Error _ -> fail (label ^ " unexpectedly failed")

let id value =
  S.Id.of_json (`Assoc [ "kind", `String "direct_operation"; "id", `String value ])
  |> require "scope ID"

let hash text = Digestif.SHA256.(digest_string text |> to_hex)

let call : Masc.Keeper_agent_result.tool_call_detail =
  { tool_name = "Execute"; provider = "fixture"; execution_outcome = Tool_result.Ok
  ; typed_outcome = None; latency_ms = 1.; task_id = None; route_evidence = None
  ; input_fingerprint = Some (hash "same-input")
  ; output_fingerprint = Some (hash "same-output") }

let record state scope call =
  let observation = S.observation_of_call call |> require "observation" in
  S.record state ~scope observation |> require "record"

let count state scope =
  S.tool_calls state ~scope |> require "scope observations" |> List.length

let detector state scope =
  S.tool_calls state ~scope |> require "scope observations"
  |> Masc.Keeper_agent_run.For_testing.repeated_exact_tool_call ~threshold:3

let checkpoint_restore state =
  let context = Masc.Keeper_context_core.create ~eio:false ~system_prompt:"scope test" in
  let checkpoint = Masc.Keeper_context_core.checkpoint_of_context context in
  let checkpoint = { checkpoint with Agent_core.Checkpoint.session_id = "scope-session"
    ; agent_name = "scope-owner"; model = "scope-model" } in
  S.save checkpoint.context state;
  let restored = Agent_core.Checkpoint.to_string checkpoint
    |> Agent_core.Checkpoint.of_string |> require "actual checkpoint codec" in
  let target = Agent_core.Context.create_sync () in
  Agent_core.Context.set target "unrelated" (`String "keep");
  let state = S.restore ~source:restored.context ~target |> require "explicit runtime restore" in
  check bool "unrelated target value retained" true
    (Agent_core.Context.get target "unrelated" = Some (`String "keep"));
  check bool "runtime projection restored" true
    (S.to_json state = S.to_json (S.load target |> require "load runtime"));
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
  S.tool_calls state ~scope:a |> require "restored evidence"
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
   | Error (S.Unknown_scope found) -> check bool "exact missing identity" true (S.Id.equal found missing)
   | _ -> fail "unknown Resume became Fresh");
  let observation = S.observation_of_call call |> require "observation" in
  match S.record S.empty ~scope:missing observation with
  | Error (S.Unknown_scope _) -> ()
  | _ -> fail "observation invented admission"

let test_observations_are_valid_before_save () =
  List.iter (fun invalid ->
    match S.observation_of_call invalid with
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
  S.save target valid;
  Agent_core.Context.set_scoped source Agent_core.Context.Session "keeper_repetition_scopes"
    (`Assoc [ "schema", `String "unsupported" ]);
  (match S.restore ~source ~target with
   | Error (S.Invalid_snapshot _) -> ()
   | _ -> fail "corrupt checkpoint reset scope state");
  check int "target retained on decode failure" 1 (count (S.load target |> require "target") a);
  let fields = match S.to_json valid with `Assoc fields -> fields | _ -> fail "object expected" in
  let rows = Yojson.Safe.Util.(S.to_json valid |> member "scopes" |> to_list) in
  let replace name value = `Assoc ((name, value) :: List.remove_assoc name fields) in
  let invalids =
    [ `Assoc (("schema", `String "duplicate") :: fields)
    ; replace "scopes" (`List (rows @ rows))
    ; replace "active" (S.Id.to_json (id "unknown-active"))
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
  S.save target newer;
  let assert_conflict label =
    (match S.restore ~source ~target with
     | Error S.Restore_target_conflict -> ()
     | _ -> fail (label ^ " erased runtime evidence"));
    check int (label ^ " preserves observations") 3
      (count (S.load target |> require "target after conflict") a) in
  assert_conflict "absent source";
  S.save source older;
  assert_conflict "older checkpoint";
  S.save source newer;
  let same = S.restore ~source ~target |> require "same checkpoint replay" in
  check int "identical restore is idempotent" 3 (count same a);
  let corrupt = `Assoc ["schema", `String "corrupt-target"] in
  Agent_core.Context.set_scoped target Agent_core.Context.Session "keeper_repetition_scopes" corrupt;
  (match S.restore ~source ~target with
   | Error (S.Invalid_snapshot _) -> ()
   | _ -> fail "corrupt target was overwritten");
  check bool "corrupt target evidence remains" true
    (Agent_core.Context.get_scoped target Agent_core.Context.Session "keeper_repetition_scopes"
     = Some corrupt)

let () =
  run "keeper repetition scope checkpoint"
    [ "scope", [ test_case "A B checkpoint restart A" `Quick test_a_b_restart_a
               ; test_case "idempotent Fresh and2+2" `Quick test_same_fresh_and_two_plus_two
               ; test_case "unknown Resume and record" `Quick test_unknown_resume_and_record
               ; test_case "valid observations before save" `Quick test_observations_are_valid_before_save
               ; test_case "invalid checkpoint preserves target" `Quick test_invalid_snapshot_does_not_clear_target
               ; test_case "restore cannot replace runtime evidence" `Quick test_restore_does_not_replace_runtime_evidence ] ]
