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
module Support = Masc.Keeper_unified_metrics_support
module WO = Masc.Keeper_world_observation
module Cap = Masc.Keeper_tool_capability_axis

(* Detector now uses Eio.Mutex (was Stdlib.Mutex; the latter raised EDEADLK
   under any fiber contention). Every public entry needs an Eio fiber
   context, so wrap each Alcotest body in Eio_main.run. *)
let with_eio f () = Eio_main.run @@ fun _env -> f ()

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_temp_config f =
  let base_path = Filename.temp_file "test_no_progress_loop_" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () -> f (Masc.Workspace.default_config base_path))

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

let budget_exhausted_no_progress_override
      ?(stop_reason = Runtime_agent.TurnBudgetExhausted { turns_used = 1; limit = 1 })
      ?(strong_evidence = false)
      ?(surface_requires_evidence = true)
      observation
  =
  Success.budget_exhausted_no_progress_threshold_override
    ~stop_reason
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
  Alcotest.(check (option int)) "scheduled no-evidence budget exhaustion fast-fails"
    (Some 1)
    (budget_exhausted_no_progress_override scheduled_observation);
  let actionable_observation =
    { scheduled_observation with claimable_task_count = 1 }
  in
  Alcotest.(check (option int)) "scheduled actionable budget exhaustion fast-fails"
    (Some 1)
    (budget_exhausted_no_progress_override actionable_observation);
  let reactive_observation =
    { scheduled_observation with pending_mentions = [ ("operator", "wake") ] }
  in
  Alcotest.(check (option int)) "reactive observation keeps default threshold"
    None
    (budget_exhausted_no_progress_override reactive_observation);
  Alcotest.(check (option int)) "strong evidence keeps default threshold"
    None
    (budget_exhausted_no_progress_override ~strong_evidence:true scheduled_observation);
  Alcotest.(check (option int)) "visible reply keeps default threshold"
    None
    (budget_exhausted_no_progress_override
       ~surface_requires_evidence:false
       scheduled_observation);
  Alcotest.(check (option int)) "completed stop keeps default threshold"
    None
    (budget_exhausted_no_progress_override
       ~stop_reason:Runtime_agent.Completed
       scheduled_observation)

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
  | Success.Internal_prose -> "internal_prose"
  | Success.Task_claim -> "task_claim"

(* [classify_delivered] is the reactive cycle whose reply is externally delivered
   to the prompting surface: a prose-only reply classifies as [User_facing]
   (exempt). [classify_internal] is the unified keeper-cycle path, where visible
   text is an internal decision/metrics artifact; prose-only output is
   [Internal_prose] and requires evidence even when a stale scope message made
   the observation channel reactive. The autonomous self-cadence path is
   [classify_auto]. Tool-precedence cases (peer/claim dominate text) are
   delivery-independent. *)
let classify_delivered ~tools ~has_visible_text =
  delivery_label
    (Success.classify_delivery ~is_autonomous:false
       ~reply_delivery:Success.Externally_delivered ~tools ~has_visible_text)

let classify_internal ~is_autonomous ~tools ~has_visible_text =
  delivery_label
    (Success.classify_delivery ~is_autonomous
       ~reply_delivery:Success.Internal_only ~tools ~has_visible_text)

let classify_auto ~tools ~has_visible_text =
  delivery_label
    (Success.classify_delivery ~is_autonomous:true
       ~reply_delivery:Success.Internal_only ~tools ~has_visible_text)

let test_classify_delivery_mapping () =
  let claim_tool = List.hd Cap.claim_task_tool_names in
  (* Pin the EXACT peer-surface set that the no-progress classifier treats as
     evidence-requiring. Intentionally an explicit literal, NOT
     [Cap.board_activity_tool_names] iterated: iterating the axis would be
     tautological (it could never detect the axis growing a 5th tool). If
     [Keeper_tool_capability_axis] adds a Board_activity tool, this assertion
     fails and forces a conscious decision about its no-progress impact —
     converting the policy<->taxonomy coupling from silent to guarded.

     vs the removed social-model [inferred_tool_surface] set
     {keeper_board_comment, keeper_board_post, keeper_broadcast}: this set adds
     [masc_keeper_msg] (keeper->keeper message; [masc_broadcast] is the public
     name of the same [keeper_broadcast] tool). That is an intentional, more
     complete peer-surface definition (RFC-0276 §2.4 / §3.2 behavior change): a
     turn that only sends a peer message with no durable evidence now accrues
     the streak, matching RFC-0239's "only posts to peers without evidence"
     intent, where the old social model let a bare keeper-msg turn reset it. *)
  let expected_peer_tools =
    [ "keeper_board_comment"
    ; "keeper_board_post"
    ; "masc_broadcast"
    ; "masc_keeper_msg"
    ]
  in
  Alcotest.(check (slist string String.compare))
    "peer-surface set is exactly the pinned list (axis-drift guard)"
    expected_peer_tools Cap.board_activity_tool_names;
  (* Every pinned peer tool -> Peer_only, with or without text: a turn that
     calls a peer-surface tool is Peer_only even when it also produced text,
     because the peer post is the salient delivery (tools dominate text). *)
  List.iter
    (fun t ->
      Alcotest.(check string)
        (Printf.sprintf "peer tool %s -> peer_only" t) "peer_only"
        (classify_delivered ~tools:[ t ] ~has_visible_text:false);
      Alcotest.(check string)
        (Printf.sprintf "peer tool %s + text -> peer_only (tools dominate text)"
           t)
        "peer_only"
        (classify_delivered ~tools:[ t ] ~has_visible_text:true))
    expected_peer_tools;
  (* Multi-signal precedence (RFC-0276 §3.2 total derivation): a turn carrying
     both a peer tool and a claim tool, plus text, is Peer_only — peer-posting
     dominates claim, which dominates text. Mirrors the removed
     inferred_tool_surface if/else-if order so the anti-thrash invariant cannot
     flip to exempt on a multi-signal turn. *)
  Alcotest.(check string) "peer + claim + text -> peer_only" "peer_only"
    (classify_delivered ~tools:[ "keeper_board_post"; claim_tool ]
       ~has_visible_text:true);
  (* Claim tool is exempt (claiming is progress, RFC-0239); claim dominates
     text. *)
  Alcotest.(check string) "claim tool -> task_claim" "task_claim"
    (classify_delivered ~tools:[ claim_tool ] ~has_visible_text:false);
  Alcotest.(check string) "claim + text -> task_claim (claim dominates text)"
    "task_claim"
    (classify_delivered ~tools:[ claim_tool ] ~has_visible_text:true);
  (* No peer/claim tool + visible text, externally-delivered REACTIVE cycle ->
     user-facing reply (exempt): replying to an external prompt is the work only
     when the reply is sent back to that surface. *)
  Alcotest.(check string)
    "no tool + text (delivered reactive) -> user_facing" "user_facing"
    (classify_delivered ~tools:[] ~has_visible_text:true);
  (* Same reactive observation facts on the unified keeper-cycle path are
     internal prose, not user-facing: the text is written to internal
     decision/metrics artifacts and does not clear the prompting lane. *)
  Alcotest.(check string)
    "no tool + text (internal reactive) -> internal_prose" "internal_prose"
    (classify_internal ~is_autonomous:false ~tools:[] ~has_visible_text:true);
  (* RFC-0294 R2a: same surface facts on an AUTONOMOUS cycle (no external prompt)
     -> internal_prose (requires evidence). *)
  Alcotest.(check string) "no tool + text (autonomous) -> internal_prose"
    "internal_prose"
    (classify_auto ~tools:[] ~has_visible_text:true);
  (* Tool precedence is autonomy-independent: a peer/claim tool still dominates
     text even on an autonomous cycle (the split only affects prose-only turns). *)
  Alcotest.(check string) "peer tool + text (autonomous) -> peer_only" "peer_only"
    (classify_auto ~tools:[ "keeper_board_post" ] ~has_visible_text:true);
  (* No peer/claim tool + no text = silent turn -> Peer_only (requires
     evidence). This is the parse-don't-validate replacement for the old
     DELIVERY_SURFACE: silent header self-declaration. *)
  Alcotest.(check string) "no tool + no text (silent) -> peer_only" "peer_only"
    (classify_delivered ~tools:[] ~has_visible_text:false);
  (* A non-peer, non-claim tool with no visible text is still routed by surface
     only (Peer_only); strong_evidence (substantive tool calls) is the separate
     channel that lets such a turn count as progress. *)
  let exec_tool = List.hd Cap.shell_command_input_tool_names in
  Alcotest.(check string) "exec-only no text -> peer_only" "peer_only"
    (classify_delivered ~tools:[ exec_tool ] ~has_visible_text:false)

let test_delivery_requires_evidence_mapping () =
  Alcotest.(check bool) "peer_only requires evidence" true
    (Success.delivery_requires_evidence Success.Peer_only);
  Alcotest.(check bool) "user_facing exempt" false
    (Success.delivery_requires_evidence Success.User_facing);
  Alcotest.(check bool) "internal_prose requires evidence" true
    (Success.delivery_requires_evidence Success.Internal_prose);
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
        (Success.classify_delivery ~is_autonomous:false
           ~reply_delivery:Success.Internal_only ~tools:[] ~has_visible_text:false)
    in
    record_turn ~keeper_name:k
      ~made_progress:
        (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence)
    |> ignore_outcome
  done;
  Alcotest.(check int) "silent no-evidence turns accrue streak" 4
    (D.current_streak ~keeper_name:k)

(* RFC-0294 R2a: an autonomous (self-cadence, no external prompt) turn that emits
   only prose and no durable evidence accrues the no-progress streak. This is the
   residual blind spot after R1g: R1g stops failed_task from *driving* the wake,
   but a keeper that still wakes (e.g. real cooldown elapse) and only says
   "nothing to do" previously reset the streak via the [User_facing] exemption.
   With the [Internal_prose] split it now requires evidence. *)
let test_autonomous_textonly_noop_accrues_streak () =
  let k = "r2a_internal_prose_thrash" in
  for _ = 1 to 4 do
    let surface_requires_evidence =
      Success.delivery_requires_evidence
        (Success.classify_delivery ~is_autonomous:true
           ~reply_delivery:Success.Internal_only ~tools:[] ~has_visible_text:true)
    in
    record_turn ~keeper_name:k
      ~made_progress:
        (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence)
    |> ignore_outcome
  done;
  Alcotest.(check int) "autonomous prose-only no-evidence turns accrue streak" 4
    (D.current_streak ~keeper_name:k)

(* RFC-0294 R2a false-positive guard: an externally-delivered REACTIVE turn that
   replies to an operator/peer with prose and no tool is legitimate work and
   stays exempt — it must NOT accrue the streak. Distinguishes the split from a
   blanket "no-tool prose is no-progress" cap. *)
let test_operator_mention_textonly_reply_exempt () =
  let k = "r2a_reactive_reply_exempt" in
  for _ = 1 to 4 do
    let surface_requires_evidence =
      Success.delivery_requires_evidence
        (Success.classify_delivery ~is_autonomous:false
           ~reply_delivery:Success.Externally_delivered ~tools:[]
           ~has_visible_text:true)
    in
    record_turn ~keeper_name:k
      ~made_progress:
        (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence)
    |> ignore_outcome
  done;
  Alcotest.(check int) "reactive prose reply does not accrue streak" 0
    (D.current_streak ~keeper_name:k)

(* Regression for the idealist passive-only loop observed on 2026-06-26: an
   owner-authored scope message stayed pending, but the unified keeper cycle's
   text response was only an internal decision/metrics artifact, not an
   assistant row appended to keeper_chat. The observation channel is reactive,
   yet the reply is not externally delivered, so prose-only output must require
   evidence and accrue the no-progress streak. *)
let test_scope_message_internal_textonly_accrues_streak () =
  let k = "r3_scope_message_internal_prose_thrash" in
  let observation =
    { scheduled_observation with
      pending_scope_messages = [ ("owner", "did you actually use tools?") ]
    }
  in
  let is_autonomous =
    Support.is_scheduled_autonomous_cycle_of_observation observation
  in
  Alcotest.(check bool)
    "scope-message observation remains reactive" false is_autonomous;
  for _ = 1 to 4 do
    let surface_requires_evidence =
      Success.delivery_requires_evidence
        (Success.classify_delivery ~is_autonomous
           ~reply_delivery:Success.Internal_only ~tools:[] ~has_visible_text:true)
    in
    record_turn ~keeper_name:k
      ~made_progress:
        (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence)
    |> ignore_outcome
  done;
  Alcotest.(check int)
    "internal scope-message prose without evidence accrues streak" 4
    (D.current_streak ~keeper_name:k)

(* task-5 keeper-stability: a passive-only turn that observed no actionable
   work and did not own an active task is legitimately idle. It must not accrue
   the no-progress streak even when the surface otherwise requires evidence.
   The exemption applies to any tool classified as [Passive_status] by
   [Keeper_tool_progress.classify_tool_progress], including peer-surface tools
   when no work/owned task exists. *)
let test_passive_only_no_work_does_not_accrue () =
  D.reset_all_for_test ();
  let k = "passive-no-work" in
  (* The classifier uses [claimable_task_count] to decide whether there is an
     actionable signal, so [unclaimed_task_count] is omitted here. *)
  let observation =
    { scheduled_observation with
      claimable_task_count = 0
    }
  in
  let is_legitimate tool_calls had_owned_active_task =
    Success.legitimate_no_work_passive_only
      ~observation
      ~tool_calls
      ~had_owned_active_task
  in
  Alcotest.(check bool) "passive-only no-work is legitimate" true
    (is_legitimate [ ("keeper_surface_read", None) ] false);
  Alcotest.(check bool) "owned active task breaks legitimacy" false
    (is_legitimate [ ("keeper_surface_read", None) ] true);
  Alcotest.(check bool) "actionable signal breaks legitimacy" false
    (Success.legitimate_no_work_passive_only
       ~observation:{ observation with claimable_task_count = 1 }
       ~tool_calls:[ ("keeper_surface_read", None) ]
       ~had_owned_active_task:false);
  (* [classify_tool_progress] currently treats [tool_execute] as [Passive_status],
     so the negative case for a non-passive tool uses a claim tool instead. *)
  Alcotest.(check bool) "non-passive tool breaks legitimacy" false
    (is_legitimate [ (List.hd Cap.claim_task_tool_names, None) ] false);
  for _ = 1 to D.threshold () do
    let surface_requires_evidence = true in
    record_turn ~keeper_name:k
      ~made_progress:
        (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence
         || is_legitimate [ ("keeper_surface_read", None) ] false)
    |> ignore_outcome
  done;
  Alcotest.(check int) "streak stays 0" 0 (D.current_streak ~keeper_name:k)
;;

(* RFC-0239 / audit D1·D3: the no-progress detector reads the typed outcome
   recorded on each tool call, not just the tool name. *)
module Outcome = Keeper_tool_outcome

let no_eligible_outcome =
  Outcome.No_progress
    { reason =
        Outcome.No_eligible_tasks
          { scope_excluded_count = 0
          ; blocked_count = 0
          ; verification_blocked_count = 0
          ; all_goals_excluded = false
          }
    }

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "trace_id", `String ("trace-" ^ name)
          ; "goal", `String "test no-progress detector"
          ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta fixture failed: " ^ err)

let prompt_metrics =
  Masc.Keeper_agent_prompt_metrics.build_prompt_metrics ~system_prompt:""
    ~dynamic_context:"" ~user_message:""

let ctx_composition : Masc.Keeper_agent_prompt_metrics.ctx_composition_metrics =
  { actual_input_tokens = None
  ; display_total_tokens = 0
  ; estimated_known_tokens = 0
  ; segments = []
  }

let tool_surface : Masc.Keeper_agent_tool_surface.tool_surface_metrics =
  { turn_lane = Masc.Keeper_agent_tool_surface.Lane_tool_optional
  ; config_root = ""
  ; runtime_config_path = None
  }

let tool_call ?typed_outcome tool_name : Masc.Keeper_agent_result.tool_call_detail =
  { tool_name
  ; provider = "test"
  ; outcome = "ok"
  ; typed_outcome
  ; latency_ms = 0.0
  ; task_id = None
  ; route_evidence = None
  }

let run_result tool_calls : Masc.Keeper_agent_run.run_result =
  { response_text = ""
  ; model_used = "test-model"
  ; prompt_metrics
  ; ctx_composition
  ; runtime_observation = None
  ; turn_count = 1
  ; usage = Masc.Inference_utils.zero_usage
  ; usage_reported = true
  ; tool_calls
  ; checkpoint = None
  ; trace_ref = None
  ; run_validation = None
  ; stop_reason = Runtime_agent.Completed
  ; inference_telemetry = None
  ; tool_surface
  ; pre_dispatch_compacted = false
  ; pre_dispatch_compaction_trigger = None
  ; pre_dispatch_compaction_before_tokens = None
  ; pre_dispatch_compaction_after_tokens = None
  }

(* audit D3: a [Task_claim] turn is exempt only when a claim bound work. A claim
   that typed [No_eligible_tasks] did not bind work (the sangsu claim-idle loop,
   PR #21065), so it must require evidence and accrue the streak. *)
let test_claim_outcome_aware_exemption () =
  let claim = List.hd Cap.claim_task_tool_names in
  Alcotest.(check bool) "claim No_eligible_tasks did not bind work" false
    (Success.claim_bound_work [ (claim, Some no_eligible_outcome) ]);
  Alcotest.(check bool) "claim Progress bound work" true
    (Success.claim_bound_work [ (claim, Some Outcome.Progress) ]);
  Alcotest.(check bool) "untyped claim stays exempt (legacy back-compat)" true
    (Success.claim_bound_work [ (claim, None) ])

(* audit D1: a completion tool that typed a failure is not substantive evidence;
   an untyped completion keeps the legacy name-based behavior. *)
let test_strong_evidence_outcome_aware () =
  let done_tool = List.hd Masc.Keeper_tool_progress.completion_tool_names in
  let claim = List.hd Cap.claim_task_tool_names in
  Alcotest.(check bool) "errored completion is not evidence" false
    (Success.has_substantive_tool_calls_with_outcome
       [ (done_tool, Some (Outcome.Error { reason = "rejected" })) ]);
  Alcotest.(check bool) "no-progress completion is not evidence" false
    (Success.has_substantive_tool_calls_with_outcome
       [ (done_tool, Some no_eligible_outcome) ]);
  Alcotest.(check bool) "successful completion is evidence" true
    (Success.has_substantive_tool_calls_with_outcome
       [ (done_tool, Some Outcome.Progress) ]);
  Alcotest.(check bool) "untyped completion keeps legacy evidence" true
    (Success.has_substantive_tool_calls_with_outcome [ (done_tool, None) ]);
  Alcotest.(check bool) "a claim is never execution evidence" false
    (Success.has_substantive_tool_calls_with_outcome
       [ (claim, Some Outcome.Progress) ])

(* End-to-end: the sangsu claim-idle loop now accrues the streak; a claim that
   bound work stays exempt. *)
let test_sangsu_claim_idle_loop_accrues () =
  let claim = List.hd Cap.claim_task_tool_names in
  let idle = [ (claim, Some no_eligible_outcome) ] in
  let strong_evidence = Success.has_substantive_tool_calls_with_outcome idle in
  let surface_requires_evidence = not (Success.claim_bound_work idle) in
  Alcotest.(check bool) "no strong evidence from a no-eligible claim" false
    strong_evidence;
  Alcotest.(check bool) "no-eligible claim now requires evidence" true
    surface_requires_evidence;
  Alcotest.(check bool) "made_progress false => streak accrues" false
    (D.turn_made_progress ~strong_evidence ~surface_requires_evidence);
  let bound = [ (claim, Some Outcome.Progress) ] in
  Alcotest.(check bool) "claim that bound work stays exempt" true
    (D.turn_made_progress ~strong_evidence:false
       ~surface_requires_evidence:(not (Success.claim_bound_work bound)))

let test_apply_loop_detectors_passive_only_no_work_does_not_accrue () =
  D.reset_all_for_test ();
  with_temp_config @@ fun config ->
  let keeper = "apply-passive-no-work" in
  let meta = make_meta keeper in
  let result = run_result [ tool_call "keeper_surface_read" ] in
  for _ = 1 to D.threshold () do
    ignore
      (Success.apply_loop_detectors ~config ~observation:scheduled_observation
         ~meta meta result)
  done;
  Alcotest.(check int) "production detector path keeps passive no-work at zero" 0
    (D.current_streak ~keeper_name:keeper)

let test_apply_loop_detectors_claim_no_eligible_accrues () =
  D.reset_all_for_test ();
  with_temp_config @@ fun config ->
  let keeper = "apply-claim-no-eligible" in
  let meta = make_meta keeper in
  let claim = List.hd Cap.claim_task_tool_names in
  let result = run_result [ tool_call ~typed_outcome:no_eligible_outcome claim ] in
  ignore
    (Success.apply_loop_detectors ~config ~observation:scheduled_observation ~meta
       meta result);
  Alcotest.(check int) "production detector path accrues typed no-eligible claim" 1
    (D.current_streak ~keeper_name:keeper)

(* RFC-0289 / SSOT: [Keeper_tool_outcome.is_nonprogress] is the single owner of
   the outcome gate (previously inlined in [typed_outcome_is_nonprogress], now a
   thin delegate). Pin its mapping directly against the variant so the
   predicate travels with the variant: a future outcome constructor added
   without updating the predicate surfaces here as an uncovered arm, and the
   legacy [None] -> false (name-based behavior) contract is fixed. *)
let test_is_nonprogress_branches () =
  Alcotest.(check bool) "None -> false (legacy name-based behavior)" false
    (Outcome.is_nonprogress None);
  Alcotest.(check bool) "Some Progress -> false" false
    (Outcome.is_nonprogress (Some Outcome.Progress));
  Alcotest.(check bool) "Some No_progress -> true" true
    (Outcome.is_nonprogress (Some no_eligible_outcome));
  Alcotest.(check bool) "Some Error -> true" true
    (Outcome.is_nonprogress (Some (Outcome.Error { reason = "rejected" })))

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
          Alcotest.test_case
            "R2a autonomous prose-only turns accrue streak"
            `Quick (with_eio test_autonomous_textonly_noop_accrues_streak);
          Alcotest.test_case
            "R2a reactive prose reply stays exempt (false-positive guard)"
            `Quick (with_eio test_operator_mention_textonly_reply_exempt);
          Alcotest.test_case
            "R3 scope-message internal prose accrues streak"
            `Quick (with_eio test_scope_message_internal_textonly_accrues_streak);
          Alcotest.test_case
            "passive-only no-work does not accrue streak (task-5)"
            `Quick (with_eio test_passive_only_no_work_does_not_accrue);
          Alcotest.test_case "claim exemption is outcome-aware (D3)"
            `Quick test_claim_outcome_aware_exemption;
          Alcotest.test_case "strong evidence drops typed-failure completions (D1)"
            `Quick test_strong_evidence_outcome_aware;
          Alcotest.test_case "sangsu claim-idle loop accrues streak"
            `Quick test_sangsu_claim_idle_loop_accrues;
          Alcotest.test_case
            "apply_loop_detectors passive-only no-work stays reset"
            `Quick (with_eio test_apply_loop_detectors_passive_only_no_work_does_not_accrue);
          Alcotest.test_case
            "apply_loop_detectors typed no-eligible claim accrues"
            `Quick (with_eio test_apply_loop_detectors_claim_no_eligible_accrues);
          Alcotest.test_case "is_nonprogress 4-arm mapping (RFC-0289 SSOT)"
            `Quick test_is_nonprogress_branches;
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
