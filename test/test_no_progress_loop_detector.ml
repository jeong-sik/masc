(* test/test_no_progress_loop_detector.ml

   #9926: detector observability contract. Pins:
   - Streak increments on consecutive no-progress turns
   - Streak resets to 0 on any progress turn
   - Detected-counter only bumps once per loop episode (latched)
   - Reset latches on streak reset
   - Threshold is the product constant
   - Per-keeper isolation *)

module D = Masc.Keeper_no_progress_loop_detector
module Metrics = Masc.Otel_metric_store
module Success = Masc.Keeper_unified_turn_success.For_testing
module WO = Masc.Keeper_world_observation
module Cap = Masc.Keeper_tool_capability_axis

(* Detector now uses Eio.Mutex (was Stdlib.Mutex; the latter raised EDEADLK
   under any fiber contention). Every public entry needs an Eio fiber
   context, so wrap each Alcotest body in Eio_main.run. *)
let with_eio f () = Eio_main.run @@ fun _env -> f ()

let detected_count keeper =
  Metrics.metric_value_or_zero
    "masc_keeper_no_progress_loop_detected_total"
    ~labels:[ ("keeper", keeper) ] ()

let record_turn ~keeper_name ~made_progress =
  D.record_turn ~keeper_name ~made_progress ()

let ignore_outcome = function
  | D.Normal | D.Loop_detected _ | D.Loop_reset _ -> ()

let scheduled_observation : WO.world_observation =
  { pending_mentions = []
  ; pending_board_events = []
  ; pending_scope_messages = []
  ; idle_seconds = 0
  ; active_goals = []
  ; continuity_summary = ""
  ; context_ratio = lazy 0.0
  ; unclaimed_task_count = 0
  ; claimable_task_count = 0
  ; provider_capacity_blocked_task_count = 0
  ; failed_task_count = 0
  ; pending_verification_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; backlog_updated_since_last_scheduled_autonomous = false
  ; running_keeper_fiber_count = 0
  ; connected_surfaces = []
  }

let no_work_budget_override
      ?(stop_reason = Runtime_agent.TurnBudgetExhausted { turns_used = 1; limit = 1 })
      ?(has_current_task = false)
      ?(active_goal_ids = [])
      ?(strong_evidence = false)
      ?(surface_requires_evidence = true)
      observation
  =
  Success.no_work_budget_threshold_override
    ~stop_reason
    ~has_current_task
    ~active_goal_ids
    ~strong_evidence
    ~surface_requires_evidence
    ~observation

let test_streak_increments () =
  D.reset_all_for_test ();
  let k = "test-keeper-increments" in
  record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome;
  Alcotest.(check int) "after 1" 1 (D.current_streak ~keeper_name:k);
  record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome;
  record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome;
  Alcotest.(check int) "after 3" 3 (D.current_streak ~keeper_name:k)

let test_any_other_act_resets () =
  D.reset_all_for_test ();
  let k = "test-keeper-resets" in
  for _ = 1 to 5 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check int) "pre-reset" 5 (D.current_streak ~keeper_name:k);
  (match record_turn ~keeper_name:k ~made_progress:true with
   | D.Loop_reset { previous_streak; was_latched } ->
     Alcotest.(check int) "reset previous streak" 5 previous_streak;
     Alcotest.(check bool) "reset was not latched" false was_latched
   | D.Normal | D.Loop_detected _ -> Alcotest.fail "expected loop reset");
  Alcotest.(check int) "after declare" 0 (D.current_streak ~keeper_name:k);
  record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome;
  Alcotest.(check int) "after new no-progress turn" 1
    (D.current_streak ~keeper_name:k)

let test_threshold_crossing_fires_counter () =
  D.reset_all_for_test ();
  let k = "test-keeper-threshold-fires" in
  let before = detected_count k in
  for _ = 1 to D.threshold () - 1 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check (float 0.0001)) "no fire before threshold" before
    (detected_count k);
  (match record_turn ~keeper_name:k ~made_progress:false with
   | D.Loop_detected { streak; threshold } ->
     Alcotest.(check int) "loop streak" threshold streak
   | D.Normal | D.Loop_reset _ -> Alcotest.fail "expected loop detection at threshold");
  Alcotest.(check (float 0.0001)) "fires at threshold"
    (before +. 1.0) (detected_count k);
  ()

let test_threshold_override_fires_early () =
  D.reset_all_for_test ();
  let k = "test-keeper-fast-latch" in
  let before = detected_count k in
  (match D.record_turn ~threshold_override:1 ~keeper_name:k ~made_progress:false () with
   | D.Loop_detected { streak; threshold } ->
     Alcotest.(check int) "fast latch streak" 1 streak;
     Alcotest.(check int) "fast latch threshold" 1 threshold
   | D.Normal | D.Loop_reset _ -> Alcotest.fail "expected fast loop detection");
  Alcotest.(check (float 0.0001)) "fast latch increments counter"
    (before +. 1.0) (detected_count k);
  Alcotest.(check int) "streak retained" 1 (D.current_streak ~keeper_name:k)

let test_no_work_budget_override_predicate () =
  Alcotest.(check (option int)) "scheduled no-work budget exhaustion fast-fails"
    (Some 1)
    (no_work_budget_override scheduled_observation);
  let reactive_observation =
    { scheduled_observation with pending_mentions = [ ("operator", "wake") ] }
  in
  Alcotest.(check (option int)) "reactive observation keeps default threshold"
    None
    (no_work_budget_override reactive_observation);
  Alcotest.(check (option int)) "active task keeps default threshold"
    None
    (no_work_budget_override ~has_current_task:true scheduled_observation);
  Alcotest.(check (option int)) "active goal keeps default threshold"
    None
    (no_work_budget_override ~active_goal_ids:[ "goal-1" ] scheduled_observation);
  Alcotest.(check (option int)) "strong evidence keeps default threshold"
    None
    (no_work_budget_override ~strong_evidence:true scheduled_observation);
  Alcotest.(check (option int)) "visible reply keeps default threshold"
    None
    (no_work_budget_override ~surface_requires_evidence:false scheduled_observation);
  Alcotest.(check (option int)) "completed stop keeps default threshold"
    None
    (no_work_budget_override ~stop_reason:Runtime_agent.Completed scheduled_observation)

let test_latched_no_repeat_while_streak_grows () =
  D.reset_all_for_test ();
  let k = "test-keeper-latched" in
  let before = detected_count k in
  for _ = 1 to D.threshold () + 7 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check (float 0.0001)) "latched: exactly +1 across long no-progress run"
    (before +. 1.0) (detected_count k)

let test_latch_releases_on_reset_then_refires () =
  D.reset_all_for_test ();
  let k = "test-keeper-relatch" in
  let before = detected_count k in
  for _ = 1 to D.threshold () + 2 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check (float 0.0001)) "first loop fires once"
    (before +. 1.0) (detected_count k);
  (* Break the loop with a progress turn. *)
  (match record_turn ~keeper_name:k ~made_progress:true with
   | D.Loop_reset { was_latched; _ } ->
     Alcotest.(check bool) "reset releases latched loop" true was_latched
   | D.Normal | D.Loop_detected _ -> Alcotest.fail "expected latched loop reset");
  (* Start a second loop. *)
  for _ = 1 to D.threshold () + 2 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check (float 0.0001)) "second loop fires once more"
    (before +. 2.0) (detected_count k)

let test_per_keeper_isolation () =
  D.reset_all_for_test ();
  let a = "test-keeper-A" in
  let b = "test-keeper-B" in
  for _ = 1 to 4 do
    record_turn ~keeper_name:a ~made_progress:false |> ignore_outcome
  done;
  record_turn ~keeper_name:b ~made_progress:false |> ignore_outcome;
  Alcotest.(check int) "A streak" 4 (D.current_streak ~keeper_name:a);
  Alcotest.(check int) "B streak" 1 (D.current_streak ~keeper_name:b);
  (* Resetting A's streak does not touch B. *)
  record_turn ~keeper_name:a ~made_progress:true |> ignore_outcome;
  Alcotest.(check int) "A reset" 0 (D.current_streak ~keeper_name:a);
  Alcotest.(check int) "B unchanged" 1 (D.current_streak ~keeper_name:b)

let test_threshold_constant_is_10 () =
  Alcotest.(check int) "default threshold" 10 (D.threshold ())

let test_threshold_env_is_ignored () =
  Unix.putenv "MASC_NO_PROGRESS_LOOP_THRESHOLD" "25";
  Alcotest.(check int) "env ignored" 10 (D.threshold ());
  Unix.putenv "MASC_NO_PROGRESS_LOOP_THRESHOLD" "notanumber";
  Alcotest.(check int) "non-numeric → default" 10 (D.threshold ());
  Unix.putenv "MASC_NO_PROGRESS_LOOP_THRESHOLD" ""

let test_explicit_reset () =
  D.reset_all_for_test ();
  let k = "test-keeper-explicit-reset" in
  for _ = 1 to 5 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check int) "pre explicit reset" 5
    (D.current_streak ~keeper_name:k);
  D.reset ~keeper_name:k;
  Alcotest.(check int) "post explicit reset" 0
    (D.current_streak ~keeper_name:k)

(* RFC-0239 §3 R3: the no-progress predicate. A turn makes progress iff it
   produced durable evidence OR was on a surface that does not require it. The
   key new case is the third one: a no-evidence turn on a peer-facing surface
   (board post) is NOT progress, so the streak accrues — the exact case the old
   literal silent speech-act check missed. *)
let test_made_progress_predicate () =
  Alcotest.(check bool) "evidence on evidence-required surface = progress" true
    (D.turn_made_progress ~strong_evidence:true ~surface_requires_evidence:true);
  Alcotest.(check bool)
    "NO evidence on evidence-required surface (board post) = no progress" false
    (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence:true);
  Alcotest.(check bool) "no evidence on non-required surface (user reply) = progress"
    true
    (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence:false);
  Alcotest.(check bool) "evidence on non-required surface = progress" true
    (D.turn_made_progress ~strong_evidence:true ~surface_requires_evidence:false)

let test_no_progress_board_post_accrues_streak () =
  (* End-to-end of the R3 fix at the detector boundary: a keeper that posts to
     the board with no evidence (made_progress=false) must accrue the streak,
     where the old detector reset it. *)
  D.reset_all_for_test ();
  let k = "test-keeper-board-thrash" in
  for _ = 1 to 4 do
    record_turn
      ~keeper_name:k
      ~made_progress:
        (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence:true)
    |> ignore_outcome
  done;
  Alcotest.(check int) "board posts without evidence accrue streak" 4
    (D.current_streak ~keeper_name:k)

(* RFC-0276 §3.2: the no-progress detector input is derived from observed turn
   facts (tool names + visible text) via [classify_delivery], replacing the LLM
   self-declared delivery_surface. These tests pin the mapping the detector
   relies on. *)
let delivery_label = function
  | Success.Peer_only -> "peer_only"
  | Success.User_facing -> "user_facing"
  | Success.Task_claim -> "task_claim"

let classify ~tools ~has_visible_text =
  delivery_label (Success.classify_delivery ~tools ~has_visible_text)

let test_classify_delivery_mapping () =
  let claim_tool = List.hd Cap.claim_task_tool_names in
  (* Every peer-surface tool (SSOT list) classifies as Peer_only, with or
     without text — the board/broadcast post is the salient delivery. *)
  List.iter
    (fun t ->
      Alcotest.(check string)
        (Printf.sprintf "board_activity tool %s -> peer_only" t)
        "peer_only"
        (classify ~tools:[ t ] ~has_visible_text:false);
      Alcotest.(check string)
        (Printf.sprintf "board_activity tool %s + text -> peer_only" t)
        "peer_only"
        (classify ~tools:[ t ] ~has_visible_text:true))
    Cap.board_activity_tool_names;
  (* Claim tool is exempt (claiming is progress, RFC-0239). *)
  Alcotest.(check string) "claim tool -> task_claim" "task_claim"
    (classify ~tools:[ claim_tool ] ~has_visible_text:false);
  (* No peer/claim tool + visible text -> user-facing reply (exempt). *)
  Alcotest.(check string) "no tool + text -> user_facing" "user_facing"
    (classify ~tools:[] ~has_visible_text:true);
  (* No peer/claim tool + no text = silent turn -> Peer_only (requires
     evidence). This is the parse-don't-validate replacement for the old
     DELIVERY_SURFACE: silent header self-declaration. *)
  Alcotest.(check string) "no tool + no text (silent) -> peer_only" "peer_only"
    (classify ~tools:[] ~has_visible_text:false);
  (* A non-peer, non-claim tool with no visible text is still routed by surface
     only (Peer_only); strong_evidence (substantive tool calls) is the separate
     channel that lets such a turn count as progress. *)
  let exec_tool = List.hd Cap.shell_command_input_tool_names in
  Alcotest.(check string) "exec-only no text -> peer_only" "peer_only"
    (classify ~tools:[ exec_tool ] ~has_visible_text:false)

let test_delivery_requires_evidence_mapping () =
  Alcotest.(check bool) "peer_only requires evidence" true
    (Success.delivery_requires_evidence Success.Peer_only);
  Alcotest.(check bool) "user_facing exempt" false
    (Success.delivery_requires_evidence Success.User_facing);
  Alcotest.(check bool) "task_claim exempt" false
    (Success.delivery_requires_evidence Success.Task_claim)

(* End-to-end: silent no-evidence turns (no tools, no visible text) accrue the
   streak through the decoupled classification path, mirroring the board-post
   anti-thrash test but via the RFC-0276 fact-derived surface. *)
let test_silent_turns_accrue_streak () =
  let k = "decouple_silent_thrash" in
  for _ = 1 to 4 do
    let surface_requires_evidence =
      Success.delivery_requires_evidence
        (Success.classify_delivery ~tools:[] ~has_visible_text:false)
    in
    record_turn ~keeper_name:k
      ~made_progress:
        (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence)
    |> ignore_outcome
  done;
  Alcotest.(check int) "silent no-evidence turns accrue streak" 4
    (D.current_streak ~keeper_name:k)

let () =
  Alcotest.run "keeper_no_progress_loop_detector"
    [
      ( "streak semantics",
        [
          Alcotest.test_case "increments on no-progress"
            `Quick (with_eio test_streak_increments);
          Alcotest.test_case "progress resets"
            `Quick (with_eio test_any_other_act_resets);
          Alcotest.test_case "explicit reset"
            `Quick (with_eio test_explicit_reset);
          Alcotest.test_case "no-progress predicate (RFC-0239 R3)"
            `Quick (with_eio test_made_progress_predicate);
          Alcotest.test_case "no-progress board post accrues streak (RFC-0239 R3)"
            `Quick (with_eio test_no_progress_board_post_accrues_streak);
        ] );
      ( "threshold crossing",
        [
          Alcotest.test_case "fires counter at threshold"
            `Quick (with_eio test_threshold_crossing_fires_counter);
          Alcotest.test_case "threshold override fires early"
            `Quick (with_eio test_threshold_override_fires_early);
          Alcotest.test_case "scheduled autonomous no-work override predicate"
            `Quick test_no_work_budget_override_predicate;
          Alcotest.test_case "latched: no repeat while streak grows"
            `Quick (with_eio test_latched_no_repeat_while_streak_grows);
          Alcotest.test_case "latch releases on reset, then re-fires"
            `Quick (with_eio test_latch_releases_on_reset_then_refires);
        ] );
      ( "RFC-0276 delivery decouple",
        [
          Alcotest.test_case "classify_delivery maps observed facts"
            `Quick test_classify_delivery_mapping;
          Alcotest.test_case "delivery_requires_evidence mapping"
            `Quick test_delivery_requires_evidence_mapping;
          Alcotest.test_case "silent no-evidence turns accrue streak"
            `Quick (with_eio test_silent_turns_accrue_streak);
        ] );
      ( "per-keeper isolation",
        [
          Alcotest.test_case "A and B independent"
            `Quick (with_eio test_per_keeper_isolation);
        ] );
      ( "threshold policy",
        [
          Alcotest.test_case "constant 10"
            `Quick (with_eio test_threshold_constant_is_10);
          Alcotest.test_case "env var ignored"
            `Quick (with_eio test_threshold_env_is_ignored);
        ] );
    ]
