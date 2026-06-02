open Masc_mcp

let check_float_option name expected actual =
  Alcotest.(check (option (float 0.0001))) name expected actual
;;

let budget =
  { Keeper_attempt_liveness.ttft_max = 5.0
  ; inter_chunk_max = 10.0
  ; attempt_wall_max = 30.0
  }
;;

let expect_streaming_continue state output =
  match state, output with
  | Keeper_attempt_liveness.Streaming _, Keeper_attempt_liveness.Continue -> ()
  | _, _ -> Alcotest.fail "expected streaming state to continue"
;;

let test_streaming_progress_is_not_wall_killed () =
  let state, _ =
    Keeper_attempt_liveness.step
      budget
      (Keeper_attempt_liveness.initial ~started_at:0.0)
      (Keeper_attempt_liveness.Chunk
         (Keeper_attempt_liveness.Stream_chunk.Answer_delta, 1.0))
  in
  let state, _ =
    Keeper_attempt_liveness.step
      budget
      state
      (Keeper_attempt_liveness.Chunk
         (Keeper_attempt_liveness.Stream_chunk.Thinking_delta, 29.0))
  in
  let state, output =
    Keeper_attempt_liveness.step budget state (Keeper_attempt_liveness.Tick 35.0)
  in
  expect_streaming_continue state output
;;

let test_inter_chunk_idle_still_kills_streaming () =
  let state, _ =
    Keeper_attempt_liveness.step
      budget
      (Keeper_attempt_liveness.initial ~started_at:0.0)
      (Keeper_attempt_liveness.Chunk
         (Keeper_attempt_liveness.Stream_chunk.Answer_delta, 1.0))
  in
  let state, output =
    Keeper_attempt_liveness.step budget state (Keeper_attempt_liveness.Tick 12.0)
  in
  match state, output with
  | ( Keeper_attempt_liveness.Failed Keeper_attempt_liveness.Inter_chunk_idle
    , Keeper_attempt_liveness.Outcome Keeper_attempt_liveness.Inter_chunk_idle ) ->
    ()
  | _, _ -> Alcotest.fail "expected inter-chunk idle kill"
;;

let test_outer_wall_disabled_when_observer_attached () =
  let got =
    Keeper_attempt_liveness_config.outer_wall_for_attempt
      ~mode:Keeper_attempt_liveness_config.Observe
      ~observer_attached:true
      ~per_provider_timeout_s:(Some 120.0)
      ~candidate_key:Keeper_attempt_liveness_config.runtime_candidate_key
  in
  check_float_option "observer owns stream liveness" None got
;;

let test_outer_wall_kept_without_observer () =
  let got =
    Keeper_attempt_liveness_config.outer_wall_for_attempt
      ~mode:Keeper_attempt_liveness_config.Enforce
      ~observer_attached:false
      ~per_provider_timeout_s:(Some 120.0)
      ~candidate_key:Keeper_attempt_liveness_config.runtime_candidate_key
  in
  check_float_option "legacy wall without observer" (Some 120.0) got
;;

let test_per_provider_timeout_does_not_set_agent_execution_cap () =
  let got =
    Keeper_turn_driver_try_provider.For_testing.max_execution_time_for_attempt
      ~per_provider_timeout_s:120.0
      ()
  in
  check_float_option "no Agent SDK wall cap" None got
;;

let test_per_provider_timeout_does_not_override_stream_idle () =
  let got =
    Keeper_turn_driver_try_provider.For_testing.stream_idle_timeout_for_attempt
      ~configured:(Some 75.0)
  in
  check_float_option "stream idle remains configured" (Some 75.0) got
;;

let () =
  Alcotest.run
    "keeper_attempt_liveness"
    [ ( "streaming"
      , [ Alcotest.test_case
            "streaming progress is not wall killed"
            `Quick
            test_streaming_progress_is_not_wall_killed
        ; Alcotest.test_case
            "inter-chunk idle still kills streaming"
            `Quick
            test_inter_chunk_idle_still_kills_streaming
        ] )
    ; ( "outer wall"
      , [ Alcotest.test_case
            "disabled when observer attached"
            `Quick
            test_outer_wall_disabled_when_observer_attached
        ; Alcotest.test_case
            "kept without observer"
            `Quick
            test_outer_wall_kept_without_observer
        ] )
    ; ( "agent sdk caps"
      , [ Alcotest.test_case
            "per-provider timeout does not set max_execution_time_s"
            `Quick
            test_per_provider_timeout_does_not_set_agent_execution_cap
        ; Alcotest.test_case
            "per-provider timeout does not override stream idle"
            `Quick
            test_per_provider_timeout_does_not_override_stream_idle
        ] )
    ]
;;
