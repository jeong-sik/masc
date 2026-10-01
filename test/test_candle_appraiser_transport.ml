(* The real declared HTTP walk and official-client admission feed the server
   appraiser. Only the CLI process edge is injected; no live provider is used. *)
open Alcotest
open Masc
module A = Candle_appraisal
module F = Exact_output_fixture
module Runs = Exact_lane_run_registry
module U = Yojson.Safe.Util

let () =
  Mirage_crypto_rng_unix.use_default ();
  Prompt_defaults.init ();
  Prompt_registry.set_markdown_dir "../config/prompts"
;;

let request =
  A.Grade { title = "Ship the ledger"; metric = Some "tests"; target_value = Some "10" }
;;

let identity : A.identity =
  { goal_id = "transport-goal"
  ; request_id = "transport-request"
  ; verification_run_id = "transport-verifier"
  }
;;

let valid_answer = `Assoc [ "grade", `String "medium" ]
let json = testable Yojson.Safe.pp Yojson.Safe.equal

let with_case f =
  let base_path = Filename.temp_dir "candle-appraiser-transport-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
       Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path)
       @@ fun () ->
       Masc_test_deps.with_process_env
         Env_config_core.config_dir_env_key
         (Some (Filename.concat base_path "config"))
       @@ fun () ->
       F.with_official_client_runtimes
       @@ fun () ->
       Eio_main.run
       @@ fun env ->
       Eio.Switch.run
       @@ fun sw ->
       let net = Eio.Stdenv.net env in
       let clock = Eio.Stdenv.clock env in
       Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
       @@ fun () -> f ~sw ~net ~clock ~base_path)
;;

let publish ~base_path ~cli_slots targets =
  let snapshot = F.resolver_snapshot ~source:base_path targets in
  ignore
    (F.publish_registry
       ~lane_id:"candle_appraiser"
       ~slot_ids:(List.map (fun (target : F.target_fixture) -> target.id) targets)
       ~cli_slot_ids:cli_slots
       snapshot
     : Runtime_exact_output_registry.t)
;;

(* The provider envelope is valid. Its model-authored content is not JSON,
   which must reach Exact.Invalid_json_output rather than a connection error. *)
let openai_text text =
  Yojson.Safe.to_string
    (`Assoc
        [ "id", `String "candle-transport-fixture"
        ; "model", `String "fixture"
        ; ( "choices"
          , `List
              [ `Assoc
                  [ "index", `Int 0
                  ; ( "message"
                    , `Assoc [ "role", `String "assistant"; "content", `String text ] )
                  ; "finish_reason", `String "stop"
                  ]
              ] )
        ; ( "usage"
          , `Assoc
              [ "prompt_tokens", `Int 1
              ; "completion_tokens", `Int 1
              ; "total_tokens", `Int 2
              ] )
        ])
;;

let malformed_body = openai_text (String.make 600 'x' ^ " not a JSON answer")

let unavailable_body =
  {|{"error":{"message":"fixture unavailable","type":"server_error"}}|}
;;

let recorded_run ~base_path =
  let registry = Runs.global () in
  let matches =
    List.filter
      (fun (run : Runs.run) -> run.lane = Runs.Candle_appraiser && run.actor = base_path)
      (Runs.list_runs registry)
  in
  match matches with
  | [ summary ] ->
    (match Runs.get registry ~run_id:summary.run_id with
     | Some run -> run
     | None -> fail "registered appraisal disappeared")
  | runs -> failf "expected one appraiser run, got %d" (List.length runs)
;;

let completed (run : Runs.run) =
  match run.status with
  | Runs.Completed { outcome; output; selected_slot; _ } -> outcome, output, selected_slot
  | Runs.Running -> fail "appraisal run was left Running"
  | Runs.Completion_persistence_failed _ -> fail "appraisal completion was not stored"
;;

let attempts output = U.(member "attempts" output |> to_list)

let dispatched output =
  attempts output
  |> List.filter_map (fun event ->
    if U.member "kind" event = `String "dispatch"
    then Some U.(member "slot" event |> to_string)
    else None)
;;

let check_http_failure ~slot ~body ~invalid output =
  let matching =
    attempts output
    |> List.filter (fun event ->
      U.member "kind" event = `String "http_failure"
      && U.member "slot" event = `String slot)
  in
  match matching with
  | [ event ] ->
    check
      string
      "complete failed HTTP body survives in exact evidence"
      body
      U.(member "raw_response" event |> to_string);
    check
      bool
      "response failure classification is retained"
      invalid
      U.(member "invalid_output" event |> to_bool)
  | events -> failf "expected one HTTP failure for %s, got %d" slot (List.length events)
;;

let check_failure code run =
  let outcome, output, selected_slot = completed run in
  (match outcome with
   | Runs.Failed failure -> check string "failure kind is observable" code failure.code
   | Runs.Succeeded | Runs.Cancelled ->
     fail "failed appraisal was recorded as another outcome");
  output, selected_slot
;;

let unavailable_cli calls : Keeper_lane_cli_oneshot.runner =
  fun ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
  calls := runtime_id :: !calls;
  Error (Fusion_official_client.Setup_failure "injected official client unavailable")
;;

let resting_cli calls : Keeper_lane_cli_oneshot.runner =
  fun ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
  calls := runtime_id :: !calls;
  Error (Fusion_official_client.Claude_failure
    (Runtime_claude_code.Quota_blocked
      { api_error_status = Some 429; rate_limit = None
      ; tool_effect_attempted = false; response_emitted = false }))
;;

let run_declared ~base_path cli_runner =
  Server_candle_appraiser.For_testing.run_declared
    ~base_path
    ~cli_runner
    ~identity
    request
;;

let test_invalid_http_then_unavailable_cli_stays_rejected () =
  with_case (fun ~sw ~net ~clock ~base_path ->
    let server = F.start_server ~sw ~net ~clock (F.Reply malformed_body) in
    let slot = "candle-malformed-json" in
    publish
      ~base_path
      ~cli_slots:[ F.cli_primary_runtime ]
      [ { F.id = slot; base_url = server.base_url } ];
    let calls = ref [] in
    (match run_declared ~base_path (unavailable_cli calls) with
     | Error (A.Invalid_response _) -> ()
     | Error (A.Transport_unavailable detail) ->
       failf "invalid HTTP output became pulse-retryable: %s" detail
     | Error (A.Execution_rejected detail) ->
       failf "invalid HTTP output lost its semantic refusal: %s" detail
     | Ok _ -> fail "malformed HTTP and unavailable CLI produced an appraisal");
    check int "HTTP candidate dispatched once" 1 (F.post_count server);
    check
      (list string)
      "declared CLI tail was attempted"
      [ F.cli_primary_runtime ]
      (List.rev !calls);
    let output, selected =
      check_failure "candle_appraisal_rejected" (recorded_run ~base_path)
    in
    check
      (option string)
      "last dispatched slot is the failed CLI"
      (Some F.cli_primary_runtime)
      selected;
    check
      (list string)
      "recorded dispatch order"
      [ slot; F.cli_primary_runtime ]
      (dispatched output);
    check_http_failure ~slot ~body:malformed_body ~invalid:true output)
;;

let test_all_transport_failures_remain_retryable () =
  List.iter (fun status ->
  with_case (fun ~sw ~net ~clock ~base_path ->
    let server =
      F.start_server
        ~sw
        ~net
        ~clock
        (F.Reply_with (fun _ _ -> status, unavailable_body))
    in
    let slot = "candle-provider-unavailable" in
    publish
      ~base_path
      ~cli_slots:[ F.cli_primary_runtime ]
      [ { F.id = slot; base_url = server.base_url } ];
    let calls = ref [] in
    (match run_declared ~base_path (resting_cli calls) with
     | Error (A.Transport_unavailable _) -> ()
     | Error (A.Invalid_response detail) ->
       failf "unavailable bindings became semantic rejection: %s" detail
     | Error (A.Execution_rejected detail) ->
       failf "resting bindings became permanent rejection: %s" detail
     | Ok _ -> fail "unavailable transports produced an appraisal");
    check int "unavailable HTTP candidate dispatched once" 1 (F.post_count server);
    check
      (list string)
      "unavailable CLI was reached"
      [ F.cli_primary_runtime ]
      (List.rev !calls);
    let output, selected =
      check_failure "candle_appraisal_unavailable" (recorded_run ~base_path)
    in
    check
      (option string)
      "unavailable CLI is the actual last slot"
      (Some F.cli_primary_runtime)
      selected;
    check_http_failure ~slot ~body:unavailable_body ~invalid:false output))
    [`Service_unavailable; `Internal_server_error]
;;

let test_http_bad_request_waits_for_change () =
  with_case (fun ~sw ~net ~clock ~base_path ->
    let body = {|{"error":{"message":"fixture bad request","type":"invalid_request_error"}}|} in
    let server = F.start_server ~sw ~net ~clock
      (F.Reply_with (fun _ _ -> `Bad_request, body)) in
    let slot = "candle-request-refused" in
    publish ~base_path ~cli_slots:[] [{F.id=slot;base_url=server.base_url}];
    let never_cli : Keeper_lane_cli_oneshot.runner =
      fun ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
      fail "no CLI slot was declared" in
    (match run_declared ~base_path never_cli with
     | Error (A.Execution_rejected _) -> ()
     | Error (A.Transport_unavailable detail | A.Invalid_response detail) ->
       failf "HTTP request refusal lost its execution cause: %s" detail
     | Ok _ -> fail "non-rest refusal produced an appraisal");
    check int "refused request dispatches once" 1 (F.post_count server);
    let output, selected = check_failure "candle_appraisal_execution_rejected"
      (recorded_run ~base_path) in
    check (option string) "receipt identifies refusing binding" (Some slot) selected;
    check (list string) "actual HTTP dispatch survives" [slot] (dispatched output);
    check_http_failure ~slot ~body ~invalid:false output)
;;

let test_rate_limit_without_cli_remains_retryable () =
  with_case (fun ~sw ~net ~clock ~base_path ->
    let body = {|{"error":{"message":"fixture rate limit","type":"rate_limit_error"}}|} in
    let server = F.start_server ~sw ~net ~clock
      (F.Reply_with (fun _ _ -> `Too_many_requests, body)) in
    let slot = "candle-rate-rest" in
    publish ~base_path ~cli_slots:[] [{F.id=slot;base_url=server.base_url}];
    let never_cli : Keeper_lane_cli_oneshot.runner =
      fun ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
      fail "no CLI slot was declared" in
    (match run_declared ~base_path never_cli with
     | Error (A.Transport_unavailable _) -> ()
     | Error (A.Execution_rejected detail | A.Invalid_response detail) ->
       failf "typed rate rest became a rejection: %s" detail
     | Ok _ -> fail "rate refusal produced an appraisal");
    check int "rate-limited HTTP dispatches once per run" 1 (F.post_count server);
    let output, _ = check_failure "candle_appraisal_unavailable" (recorded_run ~base_path) in
    check_http_failure ~slot ~body ~invalid:false output)
;;

let test_http_errored_choice_without_envelope_remains_retryable () =
  with_case (fun ~sw ~net ~clock ~base_path ->
    (* The content would be a valid grade if the provider had finished it.
       [finish_reason:error] without an error envelope instead reaches
       Complete_sync's typed Provider_interrupted branch. *)
    let body =
      {|{"id":"candle-interrupted","model":"fixture","choices":[{"index":0,"finish_reason":"error","message":{"role":"assistant","content":"{\"grade\":\"medium\"}"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|} in
    let server = F.start_server ~sw ~net ~clock (F.Reply body) in
    let slot = "candle-interrupted-choice" in
    publish ~base_path ~cli_slots:[] [{F.id=slot;base_url=server.base_url}];
    let never_cli : Keeper_lane_cli_oneshot.runner =
      fun ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
      fail "no CLI slot was declared" in
    (match run_declared ~base_path never_cli with
     | Error (A.Transport_unavailable _) -> ()
     | Error (A.Execution_rejected detail | A.Invalid_response detail) ->
       failf "interrupted provider response became a permanent rejection: %s" detail
     | Ok _ -> fail "errored choice was accepted as a completed grade");
    check int "interrupted HTTP request dispatched once" 1 (F.post_count server);
    let output, selected = check_failure "candle_appraisal_unavailable"
      (recorded_run ~base_path) in
    check (option string) "receipt identifies interrupted HTTP slot" (Some slot) selected;
    check (list string) "only actual HTTP dispatch is recorded" [slot] (dispatched output);
    check_http_failure ~slot ~body ~invalid:false output)
;;

let test_cli_setup_failure_is_not_binding_rest () =
  with_case (fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
    publish ~base_path ~cli_slots:[F.cli_primary_runtime] [];
    let calls = ref [] in
    (match run_declared ~base_path (unavailable_cli calls) with
     | Error (A.Execution_rejected _) -> ()
     | Error (A.Transport_unavailable detail | A.Invalid_response detail) ->
       failf "CLI setup failure was flattened: %s" detail
     | Ok _ -> fail "CLI setup failure produced an appraisal");
    check (list string) "declared CLI attempted once" [F.cli_primary_runtime] (List.rev !calls);
    let output, selected = check_failure "candle_appraisal_execution_rejected"
      (recorded_run ~base_path) in
    check (option string) "setup failure names the actual CLI" (Some F.cli_primary_runtime) selected;
    check (list string) "setup dispatch remains observable" [F.cli_primary_runtime] (dispatched output))
;;

let test_cli_timeout_remains_retryable () =
  with_case (fun ~sw:_ ~net:_ ~clock:_ ~base_path ->
    publish ~base_path ~cli_slots:[F.cli_primary_runtime] [];
    let calls = ref [] in
    let timeout_cli : Keeper_lane_cli_oneshot.runner =
      fun ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
      calls := runtime_id :: !calls;
      Error (Fusion_official_client.Claude_failure (Runtime_claude_code.Timeout 1.)) in
    (match run_declared ~base_path timeout_cli with
     | Error (A.Transport_unavailable _) -> ()
     | Error (A.Execution_rejected detail | A.Invalid_response detail) ->
       failf "known CLI timeout was stranded pending a change: %s" detail
     | Ok _ -> fail "CLI timeout produced an appraisal");
    check (list string) "timed out client attempted once" [F.cli_primary_runtime] (List.rev !calls);
    let output, selected = check_failure "candle_appraisal_unavailable" (recorded_run ~base_path) in
    check (option string) "timeout receipt names actual runtime" (Some F.cli_primary_runtime) selected;
    check (list string) "timeout keeps its dispatch evidence" [F.cli_primary_runtime] (dispatched output))
;;

let test_http_permanent_refusal_then_cli_rest_stays_rejected () =
  with_case (fun ~sw ~net ~clock ~base_path ->
    let body = {|{"error":{"message":"fixture refused input","type":"invalid_request_error"}}|} in
    let server = F.start_server ~sw ~net ~clock
      (F.Reply_with (fun _ _ -> `Bad_request, body)) in
    let slot = "candle-permanent-before-cli-rest" in
    publish ~base_path ~cli_slots:[F.cli_primary_runtime] [{F.id=slot;base_url=server.base_url}];
    let calls = ref [] in
    (match run_declared ~base_path (resting_cli calls) with
     | Error (A.Execution_rejected _) -> ()
     | Error (A.Transport_unavailable detail | A.Invalid_response detail) ->
       failf "CLI account rest erased the HTTP request refusal: %s" detail
     | Ok _ -> fail "two failed bindings produced an appraisal");
    check int "refused HTTP tried once" 1 (F.post_count server);
    check (list string) "resting fallback actually attempted" [F.cli_primary_runtime] (List.rev !calls);
    let output, selected = check_failure "candle_appraisal_execution_rejected"
      (recorded_run ~base_path) in
    check (option string) "receipt retains last dispatched CLI" (Some F.cli_primary_runtime) selected;
    check (list string) "both failed dispatches retained" [slot;F.cli_primary_runtime] (dispatched output);
    check_http_failure ~slot ~body ~invalid:false output)
;;

let test_invalid_http_then_valid_successor_keeps_both_slots () =
  with_case (fun ~sw ~net ~clock ~base_path ->
    let bad = F.start_server ~sw ~net ~clock (F.Reply malformed_body) in
    let good =
      F.start_server ~sw ~net ~clock (F.Reply (F.openai_response valid_answer))
    in
    let bad_slot = "candle-invalid-first"
    and good_slot = "candle-valid-second" in
    publish
      ~base_path
      ~cli_slots:[ F.cli_primary_runtime ]
      [ { F.id = bad_slot; base_url = bad.base_url }
      ; { F.id = good_slot; base_url = good.base_url }
      ];
    let cli_runner : Keeper_lane_cli_oneshot.runner =
      fun ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
      fail "valid HTTP successor must finish before the CLI tail"
    in
    let answer =
      match run_declared ~base_path cli_runner with
      | Ok answer -> answer
      | Error error -> fail (A.error_to_string error)
    in
    check
      bool
      "successor grade is accepted"
      true
      (answer.decision = A.Grade_decided Candle_grade.Medium);
    check string "answer identifies its actual HTTP slot" good_slot answer.trace.slot_id;
    check int "rejected predecessor dispatched once" 1 (F.post_count bad);
    check int "valid successor dispatched once" 1 (F.post_count good);
    let run = recorded_run ~base_path in
    check
      string
      "answer and exact evidence share the run id"
      run.run_id
      answer.trace.run_id;
    let outcome, output, selected = completed run in
    check bool "run succeeded" true (outcome = Runs.Succeeded);
    check (option string) "recorded answering slot" (Some good_slot) selected;
    check
      (list string)
      "both actual HTTP dispatches are retained"
      [ bad_slot; good_slot ]
      (dispatched output);
    check json "accepted answer is retained" valid_answer (U.member "result" output);
    check int "one successful HTTP attempt records one parsed response" 1
      (attempts output |> List.filter (fun event ->
        U.member "kind" event = `String "response"
        && U.member "slot" event = `String good_slot
        && U.member "output" event = valid_answer) |> List.length);
    check_http_failure ~slot:bad_slot ~body:malformed_body ~invalid:true output;
    let (Runs.Exact_input input) = run.input in
    check
      json
      "grade request keeps its exact domain input"
      (A.input request)
      (U.member "actual_input" input))
;;

let test_declared_cli_success_after_http_failure () =
  List.iter (fun status ->
  with_case (fun ~sw ~net ~clock ~base_path ->
    let server =
      F.start_server
        ~sw
        ~net
        ~clock
        (F.Reply_with (fun _ _ -> status, unavailable_body))
    in
    let slot = "candle-http-before-cli" in
    publish
      ~base_path
      ~cli_slots:[ F.cli_primary_runtime ]
      [ { F.id = slot; base_url = server.base_url } ];
    let raw_text = Yojson.Safe.to_string valid_answer in
    let calls = ref [] in
    let cli_runner : Keeper_lane_cli_oneshot.runner =
      fun ~runtime_id ~system_prompt ~output_schema ~prompt ->
      calls := runtime_id :: !calls;
      check string "CLI gets the standalone prompt as user input" "" system_prompt;
      check json "CLI uses the same closed domain schema" (A.schema request) output_schema;
      check
        bool
        "CLI receives the actual Goal input"
        true
        (Astring.String.is_infix ~affix:"Ship the ledger" prompt);
      Ok raw_text
    in
    let answer =
      match run_declared ~base_path cli_runner with
      | Ok answer -> answer
      | Error error -> fail (A.error_to_string error)
    in
    check int "HTTP was tried before CLI" 1 (F.post_count server);
    check
      (list string)
      "one official client dispatch"
      [ F.cli_primary_runtime ]
      (List.rev !calls);
    check
      string
      "answer trace uses the CLI runtime"
      F.cli_primary_runtime
      answer.trace.slot_id;
    let outcome, output, selected = completed (recorded_run ~base_path) in
    check bool "CLI answer completed the run" true (outcome = Runs.Succeeded);
    check
      (option string)
      "registry identifies the CLI answer"
      (Some F.cli_primary_runtime)
      selected;
    check
      (list string)
      "HTTP then CLI dispatches are recorded"
      [ slot; F.cli_primary_runtime ]
      (dispatched output);
    check json "CLI answer is retained" valid_answer (U.member "result" output);
    check int "CLI success retains one parsed response alongside its raw response" 1
      (attempts output |> List.filter (fun event ->
        U.member "kind" event = `String "response"
        && U.member "slot" event = `String F.cli_primary_runtime
        && U.member "output" event = valid_answer) |> List.length);
    check
      bool
      "CLI raw answer is retained under the actual slot"
      true
      (List.exists
         (fun event ->
            U.member "slot" event = `String F.cli_primary_runtime
            && U.member "raw_text" event = `String raw_text)
         (attempts output));
    check_http_failure ~slot ~body:unavailable_body ~invalid:false output))
    [`Service_unavailable; `Bad_request]
;;

let test_bookkeeping_terminal_remains_retryable () =
  with_case (fun ~sw ~net ~clock ~base_path:_ ->
    let module Exact = Agent_core.Exact_output in
    let server = F.start_server ~sw ~net ~clock (F.Reply {|{"input_tokens":1}|}) in
    let id = "candle-bookkeeping" in
    let snapshot = F.resolver_snapshot ~requires_token_measurement:true
      ~source:"Candle bookkeeping retry" [{F.id; base_url=server.base_url}] in
    let admitted_target = Exact.admit_target_ref snapshot id |> Result.get_ok in
    let first = Exact.make_flow_candidate ~id ~admitted_target |> Result.get_ok in
    let requirement = Exact.make_output_requirement ~schema:(A.schema request)
      ~minimum_guarantee:Exact.Json_syntax in
    let attempt = Exact.snapshot_flow ~first ~rest:[]
      ~messages:[Agent_core.Types.user_msg "appraise"] requirement
      |> Result.get_ok |> Exact.start_flow |> Result.get_ok in
    let measurement = ref None in
    let result = Exact.execute_flow_once ~net ~clock
      ~before_measurement_dispatch:(fun receipt -> measurement := Some receipt; Ok ())
      ~on_measurement_terminal:(fun _ -> Ok ())
      ~before_dispatch:(fun _ -> Error "bookkeeping unavailable")
      ~before_advance:(fun ~failed:_ ~next:_ -> fail "terminal bookkeeping must not advance")
      ~validate:(fun _ -> fail "failed dispatch must not validate") attempt in
    match result, !measurement with
    | Error (Exact.Flow_execution_terminal
        {cause=Exact.Flow_before_dispatch_callback_failed {candidate;evidence;_} as cause;_}),
        Some measurement ->
        let failures = [cause;
          Exact.Flow_attempt_start_failed {candidate=candidate.visit;
            cause=Exact.Call_id_generation_failed "entropy unavailable";evidence};
          Exact.Flow_measurement_start_failed {candidate=candidate.visit;
            cause=Exact.Measurement_operation_id_generation_failed "entropy unavailable";evidence};
          Exact.Flow_before_measurement_dispatch_callback_failed
            {measurement;cause="measurement intent unavailable";evidence};
          Exact.Flow_measurement_terminal_callback_failed
            {measurement;cause="receipt unavailable";evidence}] in
        List.iter (fun cause ->
          check bool "same flow remains terminal" true
            (Exact.flow_execution_terminal_kind cause = Exact.Non_advanceable_terminal);
          List.iter (fun rejected ->
            match Server_candle_appraiser.For_testing.terminal_error
              ~rejected ~retryable:false cause with
            | A.Transport_unavailable _ -> ()
            | A.Invalid_response _ | A.Execution_rejected _ ->
                fail "bookkeeping failure permanently rejected a payout") [false;true]) failures
    | _ -> fail "fixture did not capture terminal bookkeeping evidence")
;;

let () =
  run
    "candle_appraiser_transport"
    [ ( "declared transports"
      , [ test_case "bookkeeping terminal remains retryable" `Quick test_bookkeeping_terminal_remains_retryable
        ; test_case
            "HTTP bad request waits for a change"
            `Quick test_http_bad_request_waits_for_change
        ; test_case
            "HTTP rate limit remains binding rest"
            `Quick test_rate_limit_without_cli_remains_retryable
        ; test_case
            "HTTP errored choice without envelope remains retryable"
            `Quick test_http_errored_choice_without_envelope_remains_retryable
        ; test_case
            "CLI setup failure is not binding rest"
            `Quick test_cli_setup_failure_is_not_binding_rest
        ; test_case
            "known CLI timeout remains retryable"
            `Quick test_cli_timeout_remains_retryable
        ; test_case
            "HTTP permanent refusal survives resting CLI fallback"
            `Quick test_http_permanent_refusal_then_cli_rest_stays_rejected
        ; test_case
            "invalid HTTP then unavailable CLI remains rejected"
            `Quick
            test_invalid_http_then_unavailable_cli_stays_rejected
        ; test_case
            "all unavailable transports remain retryable"
            `Quick
            test_all_transport_failures_remain_retryable
        ; test_case
            "valid HTTP successor preserves failed predecessor evidence"
            `Quick
            test_invalid_http_then_valid_successor_keeps_both_slots
        ; test_case
            "declared official CLI can answer after HTTP failure"
            `Quick
            test_declared_cli_success_after_http_failure
        ] )
    ]
;;
