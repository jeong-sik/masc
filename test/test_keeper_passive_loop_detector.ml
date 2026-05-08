(** Tests for Keeper_passive_loop_detector (#12799).

    Pure unit tests for the streak counter, detection latch, and reset.
    No Eio fibers needed — the module uses Eio.Mutex but Eio_main.run wraps
    each test that exercises concurrent access. *)

open Alcotest
module PLD = Masc_mcp.Keeper_passive_loop_detector
module P = Masc_mcp.Prometheus

(* ── Helpers ──────────────────────────────────────────────────────── *)

let setup () = PLD.reset_all_for_test ()

(* ── Tests ──────────────────────────────────────────────────────────── *)

let test_initial_streak_zero () =
  Eio_main.run @@ fun _env ->
  setup ();
  check int "no-state keeper streak = 0" 0
    (PLD.current_streak ~keeper_name:"k1")

let test_passive_increments_streak () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"passive_status";
  check int "2 passives → streak 2" 2
    (PLD.current_streak ~keeper_name:"k1")

let test_claim_context_increments_streak () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"claim_context";
  check int "claim_context increments" 1
    (PLD.current_streak ~keeper_name:"k1")

let test_terminal_reason_maps_required_tool_failures () =
  check (option string) "no tool call maps to detector class"
    (Some "required_tool_no_call")
    (PLD.progress_class_of_terminal_reason_code
       "required_tool_use_no_tool_call");
  check (option string) "unsatisfied maps to detector class"
    (Some "required_tool_unsatisfied")
    (PLD.progress_class_of_terminal_reason_code
       "required_tool_use_unsatisfied");
  check (option string) "provider errors do not count"
    None
    (PLD.progress_class_of_terminal_reason_code "provider_error")

let test_required_tool_no_call_fires_metric_at_three () =
  Eio_main.run @@ fun _env ->
  setup ();
  let labels =
    [ ("keeper", "k-required-no-call"); ("kind", "required_tool_no_call") ]
  in
  let before =
    P.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_required_tool_loop_detected_total
      ~labels ()
  in
  let zombie_before =
    P.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_zombie_loop_detected_total
      ~labels:[("keeper_name", "k-required-no-call")]
      ()
  in
  PLD.record_turn ~keeper_name:"k-required-no-call"
    ~progress_class:"required_tool_no_call";
  PLD.record_turn ~keeper_name:"k-required-no-call"
    ~progress_class:"required_tool_no_call";
  check int "below required-tool threshold" 2
    (PLD.current_streak ~keeper_name:"k-required-no-call");
  check (float 0.001) "no metric before threshold" before
    (P.metric_value_or_zero
       Masc_mcp.Keeper_metrics.metric_keeper_required_tool_loop_detected_total
       ~labels ());
  PLD.record_turn ~keeper_name:"k-required-no-call"
    ~progress_class:"required_tool_no_call";
  check int "at required-tool threshold" 3
    (PLD.current_streak ~keeper_name:"k-required-no-call");
  check (float 0.001) "required-tool metric increments once"
    (before +. 1.0)
    (P.metric_value_or_zero
       Masc_mcp.Keeper_metrics.metric_keeper_required_tool_loop_detected_total
       ~labels ());
  check (float 0.001) "Observe zombie-loop metric increments once"
    (zombie_before +. 1.0)
    (P.metric_value_or_zero
       Masc_mcp.Keeper_metrics.metric_keeper_zombie_loop_detected_total
       ~labels:[("keeper_name", "k-required-no-call")]
       ())

let test_required_tool_streak_does_not_inherit_passive_streak () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"k-family" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k-family" ~progress_class:"passive_status";
  check int "passive streak starts" 2
    (PLD.current_streak ~keeper_name:"k-family");
  PLD.record_turn ~keeper_name:"k-family"
    ~progress_class:"required_tool_no_call";
  check int "required-tool family starts its own streak" 1
    (PLD.current_streak ~keeper_name:"k-family")

let test_required_tool_nudge_mentions_real_tool_call () =
  Eio_main.run @@ fun _env ->
  setup ();
  for _ = 1 to 3 do
    PLD.record_turn ~keeper_name:"k-required-nudge"
      ~progress_class:"required_tool_no_call"
  done;
  match PLD.nudge_message ~keeper_name:"k-required-nudge" with
  | None -> fail "expected required-tool nudge at threshold"
  | Some msg ->
      check bool "nudge names required tool loop" true
        (Re.execp (Re.compile (Re.str "REQUIRED TOOL LOOP")) msg);
      check bool "nudge requires real keeper tool" true
        (Re.execp (Re.compile (Re.str "real keeper tool call")) msg)

let test_execution_resets_streak () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"execution";
  check int "execution resets streak to 0" 0
    (PLD.current_streak ~keeper_name:"k1")

let test_completion_resets_streak () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"completion";
  check int "completion resets streak to 0" 0
    (PLD.current_streak ~keeper_name:"k1")

let test_detection_fires_metric_at_threshold () =
  Eio_main.run @@ fun _env ->
  setup ();
  (* Default threshold is 5. Fire exactly 5 passive turns and check metric. *)
  let before =
    P.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_passive_loop_detected_total
      ~labels:[("keeper", "k-metric")] ()
  in
  let zombie_before =
    P.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_zombie_loop_detected_total
      ~labels:[("keeper_name", "k-metric")] ()
  in
  for _ = 1 to 5 do
    PLD.record_turn ~keeper_name:"k-metric" ~progress_class:"passive_status"
  done;
  let after =
    P.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_passive_loop_detected_total
      ~labels:[("keeper", "k-metric")] ()
  in
  let zombie_after =
    P.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_zombie_loop_detected_total
      ~labels:[("keeper_name", "k-metric")] ()
  in
  check bool "metric incremented at threshold" true (after > before);
  check (float 0.001) "Observe zombie-loop metric increments"
    (zombie_before +. 1.0) zombie_after

let test_detection_latch_does_not_double_fire () =
  Eio_main.run @@ fun _env ->
  setup ();
  let before =
    P.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_passive_loop_detected_total
      ~labels:[("keeper", "k-latch")] ()
  in
  let zombie_before =
    P.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_zombie_loop_detected_total
      ~labels:[("keeper_name", "k-latch")] ()
  in
  (* Fire well above threshold — latch should prevent repeated increments *)
  for _ = 1 to 20 do
    PLD.record_turn ~keeper_name:"k-latch" ~progress_class:"passive_status"
  done;
  let after =
    P.metric_value_or_zero
      Masc_mcp.Keeper_metrics.metric_keeper_passive_loop_detected_total
      ~labels:[("keeper", "k-latch")] ()
  in
  check (float 0.001) "latch: counter increments exactly once per episode"
    (before +. 1.0) after;
  check (float 0.001)
    "latch: Observe zombie-loop counter increments exactly once per episode"
    (zombie_before +. 1.0)
    (P.metric_value_or_zero
       Masc_mcp.Keeper_metrics.metric_keeper_zombie_loop_detected_total
       ~labels:[("keeper_name", "k-latch")] ())

let test_reset_clears_state () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"k-reset" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k-reset" ~progress_class:"passive_status";
  PLD.reset ~keeper_name:"k-reset";
  check int "after reset streak = 0" 0
    (PLD.current_streak ~keeper_name:"k-reset")

let test_independent_keepers () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"ka" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"ka" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"kb" ~progress_class:"execution";
  check int "ka streak unaffected by kb" 2
    (PLD.current_streak ~keeper_name:"ka");
  check int "kb streak = 0 (execution)" 0
    (PLD.current_streak ~keeper_name:"kb")

(* ── nudge_message tests ──────────────────────────────────────────── *)

let test_nudge_message_none_before_threshold () =
  Eio_main.run @@ fun _env ->
  setup ();
  (* Below threshold — no nudge yet *)
  PLD.record_turn ~keeper_name:"k-nudge-below" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k-nudge-below" ~progress_class:"passive_status";
  let msg = PLD.nudge_message ~keeper_name:"k-nudge-below" in
  check bool "nudge is None before threshold" true (Option.is_none msg)

let test_nudge_message_some_at_threshold () =
  Eio_main.run @@ fun _env ->
  setup ();
  (* Reach the default threshold (5) — nudge should fire *)
  for _ = 1 to 5 do
    PLD.record_turn ~keeper_name:"k-nudge-at" ~progress_class:"passive_status"
  done;
  let msg = PLD.nudge_message ~keeper_name:"k-nudge-at" in
  check bool "nudge is Some at threshold" true (Option.is_some msg)

let test_nudge_message_some_above_threshold () =
  Eio_main.run @@ fun _env ->
  setup ();
  (* Above threshold — nudge should persist *)
  for _ = 1 to 8 do
    PLD.record_turn ~keeper_name:"k-nudge-above" ~progress_class:"passive_status"
  done;
  let msg = PLD.nudge_message ~keeper_name:"k-nudge-above" in
  check bool "nudge persists above threshold" true (Option.is_some msg)

let test_nudge_message_none_after_reset () =
  Eio_main.run @@ fun _env ->
  setup ();
  (* Reach threshold, then reset via an execution turn *)
  for _ = 1 to 5 do
    PLD.record_turn ~keeper_name:"k-nudge-reset" ~progress_class:"passive_status"
  done;
  let before_reset = PLD.nudge_message ~keeper_name:"k-nudge-reset" in
  check bool "nudge active before reset" true (Option.is_some before_reset);
  PLD.record_turn ~keeper_name:"k-nudge-reset" ~progress_class:"execution";
  let after_reset = PLD.nudge_message ~keeper_name:"k-nudge-reset" in
  check bool "nudge cleared after execution turn" true (Option.is_none after_reset)

let test_nudge_message_none_for_unknown_keeper () =
  Eio_main.run @@ fun _env ->
  setup ();
  let msg = PLD.nudge_message ~keeper_name:"unknown-keeper-xyz" in
  check bool "nudge is None for unknown keeper" true (Option.is_none msg)

let test_nudge_message_contains_streak_count () =
  Eio_main.run @@ fun _env ->
  setup ();
  for _ = 1 to 5 do
    PLD.record_turn ~keeper_name:"k-nudge-streak" ~progress_class:"passive_status"
  done;
  let msg = PLD.nudge_message ~keeper_name:"k-nudge-streak" in
  match msg with
  | None -> fail "expected Some nudge at threshold"
  | Some text ->
    (* The nudge message must include the streak count in context (e.g.
       "completed 5 consecutive turns") so the keeper knows how many
       passive turns have accumulated. *)
    check bool "nudge text contains 'completed 5'" true
      (let re = Re.compile (Re.str "completed 5") in
       Re.execp re text)

let () =
  run "keeper_passive_loop_detector" [
    "streak", [
      test_case "initial streak = 0" `Quick test_initial_streak_zero;
      test_case "passive_status increments streak" `Quick
        test_passive_increments_streak;
      test_case "claim_context increments streak" `Quick
        test_claim_context_increments_streak;
      test_case "terminal reason maps required-tool failures" `Quick
        test_terminal_reason_maps_required_tool_failures;
      test_case "required-tool no-call fires at 3" `Quick
        test_required_tool_no_call_fires_metric_at_three;
      test_case "required-tool streak is separate from passive streak" `Quick
        test_required_tool_streak_does_not_inherit_passive_streak;
      test_case "required-tool nudge asks for real tool" `Quick
        test_required_tool_nudge_mentions_real_tool_call;
      test_case "execution resets streak" `Quick
        test_execution_resets_streak;
      test_case "completion resets streak" `Quick
        test_completion_resets_streak;
    ];
    "detection", [
      test_case "metric fires at threshold" `Quick
        test_detection_fires_metric_at_threshold;
      test_case "latch prevents double-fire per episode" `Quick
        test_detection_latch_does_not_double_fire;
    ];
    "reset", [
      test_case "reset clears streak" `Quick test_reset_clears_state;
    ];
    "independence", [
      test_case "keepers are tracked independently" `Quick
        test_independent_keepers;
    ];
    "nudge_message", [
      test_case "None before threshold" `Quick
        test_nudge_message_none_before_threshold;
      test_case "Some at threshold" `Quick
        test_nudge_message_some_at_threshold;
      test_case "Some persists above threshold" `Quick
        test_nudge_message_some_above_threshold;
      test_case "None after execution reset" `Quick
        test_nudge_message_none_after_reset;
      test_case "None for unknown keeper" `Quick
        test_nudge_message_none_for_unknown_keeper;
      test_case "nudge text contains streak count" `Quick
        test_nudge_message_contains_streak_count;
    ];
  ]
