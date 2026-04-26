(** Tests for Thompson_sampling module — Thompson Sampling with fairness *)

open Alcotest
open Masc_mcp

(** {1 Beta Distribution Sampling Tests} *)

let test_sample_beta_range () =
  (* Run multiple samples and verify they fall in [0, 1] *)
  for _ = 1 to 100 do
    let s = Thompson_sampling.sample_beta ~alpha:1.0 ~beta:1.0 in
    check bool "beta sample >= 0" true (s >= 0.0);
    check bool "beta sample <= 1" true (s <= 1.0)
  done
;;

let test_sample_beta_skew_high_alpha () =
  (* High alpha = skewed toward 1 *)
  let samples =
    List.init 100 (fun _ -> Thompson_sampling.sample_beta ~alpha:10.0 ~beta:1.0)
  in
  let mean = List.fold_left ( +. ) 0.0 samples /. 100.0 in
  (* With alpha=10, beta=1, expected mean is 10/11 ≈ 0.91 *)
  check bool "mean > 0.7 for high alpha" true (mean > 0.7)
;;

let test_sample_beta_skew_high_beta () =
  (* High beta = skewed toward 0 *)
  let samples =
    List.init 100 (fun _ -> Thompson_sampling.sample_beta ~alpha:1.0 ~beta:10.0)
  in
  let mean = List.fold_left ( +. ) 0.0 samples /. 100.0 in
  (* With alpha=1, beta=10, expected mean is 1/11 ≈ 0.09 *)
  check bool "mean < 0.3 for high beta" true (mean < 0.3)
;;

let test_sample_beta_clamp_minimum () =
  (* Very small alpha/beta should be clamped to 0.1 *)
  let _ = Thompson_sampling.sample_beta ~alpha:0.01 ~beta:0.01 in
  (* Should not crash *)
  ()
;;

(** {1 Starvation Bonus Tests} *)

let test_starvation_bonus_zero_ticks () =
  let bonus = Thompson_sampling.starvation_bonus ~ticks:0 in
  check (float 0.01) "zero ticks = zero bonus" 0.0 bonus
;;

let test_starvation_bonus_logarithmic () =
  let b6 = Thompson_sampling.starvation_bonus ~ticks:6 in
  let b12 = Thompson_sampling.starvation_bonus ~ticks:12 in
  let b24 = Thompson_sampling.starvation_bonus ~ticks:24 in
  let b48 = Thompson_sampling.starvation_bonus ~ticks:48 in
  (* Logarithmic growth: each doubling adds less *)
  check bool "6 ticks bonus > 0" true (b6 > 0.0);
  check bool "12 > 6" true (b12 > b6);
  check bool "24 > 12" true (b24 > b12);
  check bool "48 > 24" true (b48 > b24);
  (* But growth should slow down (logarithmic not linear) *)
  let delta_6_12 = b12 -. b6 in
  let delta_24_48 = b48 -. b24 in
  check bool "growth slows (log)" true (delta_24_48 < delta_6_12 *. 1.5)
;;

let test_starvation_bonus_bounded () =
  (* Even after 1000 ticks, bonus should be reasonable *)
  let b1000 = Thompson_sampling.starvation_bonus ~ticks:1000 in
  check bool "1000 ticks bonus < 2.0" true (b1000 < 2.0)
;;

(** {1 Stats Management Tests} *)

let test_init_agent () =
  Thompson_sampling.init_agent "test-agent-1";
  let stats = Thompson_sampling.get_stats "test-agent-1" in
  check string "name matches" "test-agent-1" stats.name;
  check (float 0.01) "default alpha" 1.0 stats.alpha;
  check (float 0.01) "default beta" 1.0 stats.beta;
  check int "initial selections" 0 stats.selections
;;

let test_record_selection () =
  Thompson_sampling.init_agent "test-agent-2";
  let before = Thompson_sampling.get_stats "test-agent-2" in
  let before_selections = before.selections in
  Thompson_sampling.record_selection ~agent_name:"test-agent-2";
  let after = Thompson_sampling.get_stats "test-agent-2" in
  check int "selections incremented" (before_selections + 1) after.selections;
  check bool "last_selected_at updated" true (after.last_selected_at > 0.0)
;;

let test_record_action_post () =
  Thompson_sampling.init_agent "test-agent-3";
  let before = Thompson_sampling.get_stats "test-agent-3" in
  let before_posts = before.posts_created in
  Thompson_sampling.record_action ~agent_name:"test-agent-3" ~action:`Post;
  let after = Thompson_sampling.get_stats "test-agent-3" in
  check int "posts incremented" (before_posts + 1) after.posts_created
;;

let test_record_action_skip () =
  Thompson_sampling.init_agent "test-agent-4";
  let before = Thompson_sampling.get_stats "test-agent-4" in
  let before_skips = before.skips in
  Thompson_sampling.record_action ~agent_name:"test-agent-4" ~action:`Skip;
  let after = Thompson_sampling.get_stats "test-agent-4" in
  check int "skips incremented" (before_skips + 1) after.skips
;;

(** {1 Vote Feedback Tests} *)

let test_record_vote_pending () =
  Thompson_sampling.init_agent "test-agent-5";
  Thompson_sampling.record_vote ~agent_name:"test-agent-5" ~direction:`Up;
  Thompson_sampling.record_vote ~agent_name:"test-agent-5" ~direction:`Up;
  Thompson_sampling.record_vote ~agent_name:"test-agent-5" ~direction:`Down;
  (* Votes are pending until flush *)
  let before = Thompson_sampling.get_stats "test-agent-5" in
  check int "total_votes_up unchanged before flush" 0 before.total_votes_up;
  Thompson_sampling.flush_pending_votes ();
  let after = Thompson_sampling.get_stats "test-agent-5" in
  check int "total_votes_up after flush" 2 after.total_votes_up;
  check int "total_votes_down after flush" 1 after.total_votes_down
;;

let test_vote_updates_alpha_beta () =
  Thompson_sampling.init_agent "test-agent-6";
  let before = Thompson_sampling.get_stats "test-agent-6" in
  let before_alpha = before.alpha in
  (* Record all upvotes (100% success rate) *)
  for _ = 1 to 10 do
    Thompson_sampling.record_vote ~agent_name:"test-agent-6" ~direction:`Up
  done;
  Thompson_sampling.flush_pending_votes ();
  let after = Thompson_sampling.get_stats "test-agent-6" in
  (* Alpha should increase with positive votes *)
  check bool "alpha increased" true (after.alpha > before_alpha)
;;

(** {1 Selection Algorithm Tests} *)

let test_select_empty_agents () =
  let results =
    Thompson_sampling.select_with_feedback
      ~agents:[]
      ~max_n:3
      ~pending_triggers:[]
      ~tick_interval_s:14400.0
  in
  check int "empty agents = empty selection" 0 (List.length results)
;;

let test_select_respects_max_n () =
  let agents = [ "agent-a"; "agent-b"; "agent-c"; "agent-d"; "agent-e" ] in
  List.iter Thompson_sampling.init_agent agents;
  let results =
    Thompson_sampling.select_with_feedback
      ~agents
      ~max_n:2
      ~pending_triggers:[]
      ~tick_interval_s:14400.0
  in
  check int "respects max_n" 2 (List.length results)
;;

let test_select_mentioned_priority () =
  let agents = [ "agent-x"; "agent-y"; "agent-z" ] in
  List.iter Thompson_sampling.init_agent agents;
  let triggers = [ "agent-y", Thompson_sampling.Mentioned "test mention" ] in
  let results =
    Thompson_sampling.select_with_feedback
      ~agents
      ~max_n:2
      ~pending_triggers:triggers
      ~tick_interval_s:14400.0
  in
  (* Mentioned agent should be first *)
  check
    bool
    "mentioned agent selected"
    true
    (List.exists (fun r -> r.Thompson_sampling.agent_name = "agent-y") results);
  let first = List.hd results in
  check string "mentioned agent is first" "agent-y" first.agent_name
;;

let test_select_content_alert_priority () =
  let agents = [ "agent-p"; "agent-q"; "agent-r" ] in
  List.iter Thompson_sampling.init_agent agents;
  let triggers = [ "agent-r", Thompson_sampling.ContentAlert "urgent content" ] in
  let results =
    Thompson_sampling.select_with_feedback
      ~agents
      ~max_n:2
      ~pending_triggers:triggers
      ~tick_interval_s:14400.0
  in
  check
    bool
    "content alert agent selected"
    true
    (List.exists (fun r -> r.Thompson_sampling.agent_name = "agent-r") results)
;;

let test_stronger_trigger_replaces_weaker_duplicate () =
  let agents = [ "agent-dupe" ] in
  List.iter Thompson_sampling.init_agent agents;
  let triggers =
    [ "agent-dupe", Thompson_sampling.ContentAlert "alert"
    ; "agent-dupe", Thompson_sampling.Mentioned "mention"
    ]
  in
  let results =
    Thompson_sampling.select_with_feedback
      ~agents
      ~max_n:1
      ~pending_triggers:triggers
      ~tick_interval_s:14400.0
  in
  let selected = List.hd results in
  match selected.Thompson_sampling.trigger with
  | Thompson_sampling.Mentioned _ -> ()
  | _ -> fail "expected Mentioned trigger to override ContentAlert"
;;

let test_stronger_trigger_uses_winner_order () =
  let agents = [ "agent-a"; "agent-b" ] in
  List.iter Thompson_sampling.init_agent agents;
  let triggers =
    [ "agent-a", Thompson_sampling.ContentAlert "alert-first"
    ; "agent-b", Thompson_sampling.Mentioned "mention-b"
    ; "agent-a", Thompson_sampling.Mentioned "mention-a"
    ]
  in
  let results =
    Thompson_sampling.select_with_feedback
      ~agents
      ~max_n:2
      ~pending_triggers:triggers
      ~tick_interval_s:14400.0
  in
  let first = List.hd results in
  check
    string
    "winner ordering follows stronger trigger position"
    "agent-b"
    first.agent_name
;;

(** {1 Quality Signal Tests (Phase 3)} *)

module Pv = Masc_mcp.Post_verifier
module Ah = Masc_mcp.Agent_health

let float_eq ?(eps = 0.001) a b = Float.abs (a -. b) < eps

(* Reset agent stats for test isolation *)
let fresh_agent name =
  Thompson_sampling.init_agent name;
  let s = Thompson_sampling.get_stats name in
  s.alpha <- 1.0;
  s.beta <- 1.0;
  s.selections <- 0;
  s.last_selected_at <- 0.0;
  s.total_votes_up <- 0;
  s.total_votes_down <- 0;
  s.posts_created <- 0;
  s.comments_created <- 0;
  s.skips <- 0;
  s.updated_at <- 0.0;
  s
;;

let test_quality_pass_boosts_alpha () =
  let s = fresh_agent "qs-pass" in
  let orig_alpha = s.alpha in
  let orig_beta = s.beta in
  Thompson_sampling.record_quality_signal ~agent_name:"qs-pass" ~verdict:Pv.Pass;
  check bool "alpha +0.3" true (float_eq s.alpha (orig_alpha +. 0.3));
  check bool "beta unchanged" true (float_eq s.beta orig_beta)
;;

let test_quality_warn_nudges_beta () =
  let s = fresh_agent "qs-warn" in
  let orig_alpha = s.alpha in
  let orig_beta = s.beta in
  Thompson_sampling.record_quality_signal
    ~agent_name:"qs-warn"
    ~verdict:(Pv.Warn "filler_content");
  check bool "alpha unchanged" true (float_eq s.alpha orig_alpha);
  check bool "beta +0.1" true (float_eq s.beta (orig_beta +. 0.1))
;;

let test_quality_fail_penalizes_beta () =
  let s = fresh_agent "qs-fail" in
  let orig_alpha = s.alpha in
  let orig_beta = s.beta in
  Thompson_sampling.record_quality_signal
    ~agent_name:"qs-fail"
    ~verdict:(Pv.Fail "too_short");
  check bool "alpha unchanged" true (float_eq s.alpha orig_alpha);
  check bool "beta +0.5" true (float_eq s.beta (orig_beta +. 0.5))
;;

let test_quality_signal_floor () =
  let s = fresh_agent "qs-floor" in
  s.alpha <- 0.05;
  s.beta <- 0.05;
  Thompson_sampling.record_quality_signal ~agent_name:"qs-floor" ~verdict:(Pv.Fail "bad");
  check bool "alpha >= 0.1" true (s.alpha >= 0.1);
  check bool "beta >= 0.1" true (s.beta >= 0.1)
;;

let test_quality_cumulative () =
  let s = fresh_agent "qs-cumul" in
  Thompson_sampling.record_quality_signal ~agent_name:"qs-cumul" ~verdict:Pv.Pass;
  Thompson_sampling.record_quality_signal ~agent_name:"qs-cumul" ~verdict:Pv.Pass;
  Thompson_sampling.record_quality_signal ~agent_name:"qs-cumul" ~verdict:Pv.Pass;
  check bool "3x Pass → alpha ~1.9" true (float_eq s.alpha 1.9);
  check bool "beta unchanged" true (float_eq s.beta 1.0)
;;

(** {1 Health Gate Tests (Phase 3)} *)

let test_unhealthy_excluded_from_thompson () =
  let _ = fresh_agent "hg-healthy" in
  let _ = fresh_agent "hg-sick" in
  for _ = 1 to 10 do
    Ah.record_failure ~agent_name:"hg-sick" ~reason:"test_fail"
  done;
  let results =
    Thompson_sampling.select_with_feedback
      ~agents:[ "hg-healthy"; "hg-sick" ]
      ~max_n:2
      ~pending_triggers:[]
      ~tick_interval_s:60.0
  in
  let has_sick =
    List.exists (fun r -> r.Thompson_sampling.agent_name = "hg-sick") results
  in
  check bool "unhealthy excluded" false has_sick
;;

let test_mentioned_bypasses_health () =
  let _ = fresh_agent "hg-mentioned" in
  for _ = 1 to 10 do
    Ah.record_failure ~agent_name:"hg-mentioned" ~reason:"test_fail"
  done;
  let results =
    Thompson_sampling.select_with_feedback
      ~agents:[ "hg-mentioned" ]
      ~max_n:1
      ~pending_triggers:[ "hg-mentioned", Thompson_sampling.Mentioned "by-test" ]
      ~tick_interval_s:60.0
  in
  let selected =
    List.exists (fun r -> r.Thompson_sampling.agent_name = "hg-mentioned") results
  in
  check bool "mentioned bypasses health gate" true selected
;;

let test_content_alert_respects_health () =
  let _ = fresh_agent "hg-alert" in
  for _ = 1 to 10 do
    Ah.record_failure ~agent_name:"hg-alert" ~reason:"test_fail"
  done;
  let results =
    Thompson_sampling.select_with_feedback
      ~agents:[ "hg-alert" ]
      ~max_n:1
      ~pending_triggers:[ "hg-alert", Thompson_sampling.ContentAlert "needs-attention" ]
      ~tick_interval_s:60.0
  in
  let selected =
    List.exists (fun r -> r.Thompson_sampling.agent_name = "hg-alert") results
  in
  check bool "content alert respects health gate" false selected
;;

(** {1 Selection Entropy Tests} *)

let test_selection_entropy_empty () =
  (* Clear any existing stats for entropy calculation *)
  let entropy = Thompson_sampling.selection_entropy () in
  (* With some agents having selections, entropy should be positive *)
  check bool "entropy is non-negative" true (entropy >= 0.0)
;;

(** {1 Test Runner} *)

let () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run
    "Thompson_sampling"
    [ ( "beta_sampling"
      , [ test_case "sample in [0,1] range" `Quick test_sample_beta_range
        ; test_case "high alpha skew" `Quick test_sample_beta_skew_high_alpha
        ; test_case "high beta skew" `Quick test_sample_beta_skew_high_beta
        ; test_case "clamp minimum" `Quick test_sample_beta_clamp_minimum
        ] )
    ; ( "starvation_bonus"
      , [ test_case "zero ticks" `Quick test_starvation_bonus_zero_ticks
        ; test_case "logarithmic growth" `Quick test_starvation_bonus_logarithmic
        ; test_case "bounded growth" `Quick test_starvation_bonus_bounded
        ] )
    ; ( "stats_management"
      , [ test_case "init_agent" `Quick test_init_agent
        ; test_case "record_selection" `Quick test_record_selection
        ; test_case "record_action post" `Quick test_record_action_post
        ; test_case "record_action skip" `Quick test_record_action_skip
        ] )
    ; ( "vote_feedback"
      , [ test_case "pending votes" `Quick test_record_vote_pending
        ; test_case "alpha/beta update" `Quick test_vote_updates_alpha_beta
        ] )
    ; ( "selection"
      , [ test_case "empty agents" `Quick test_select_empty_agents
        ; test_case "respects max_n" `Quick test_select_respects_max_n
        ; test_case "mentioned priority" `Quick test_select_mentioned_priority
        ; test_case "content alert priority" `Quick test_select_content_alert_priority
        ; test_case
            "stronger trigger overrides weaker duplicate"
            `Quick
            test_stronger_trigger_replaces_weaker_duplicate
        ; test_case
            "stronger trigger uses winner order"
            `Quick
            test_stronger_trigger_uses_winner_order
        ] )
    ; ( "quality_signal"
      , [ test_case "pass boosts alpha" `Quick test_quality_pass_boosts_alpha
        ; test_case "warn nudges beta" `Quick test_quality_warn_nudges_beta
        ; test_case "fail penalizes beta" `Quick test_quality_fail_penalizes_beta
        ; test_case "signal floor" `Quick test_quality_signal_floor
        ; test_case "cumulative signals" `Quick test_quality_cumulative
        ] )
    ; ( "health_gate"
      , [ test_case "unhealthy excluded" `Quick test_unhealthy_excluded_from_thompson
        ; test_case "mentioned bypasses health" `Quick test_mentioned_bypasses_health
        ; test_case
            "content alert respects health"
            `Quick
            test_content_alert_respects_health
        ] )
    ; "monitoring", [ test_case "selection entropy" `Quick test_selection_entropy_empty ]
    ]
;;
