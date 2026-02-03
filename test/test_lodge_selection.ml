(** Tests for Lodge_selection module — Thompson Sampling with fairness *)

open Alcotest
open Masc_mcp

(** {1 Beta Distribution Sampling Tests} *)

let test_sample_beta_range () =
  (* Run multiple samples and verify they fall in [0, 1] *)
  for _ = 1 to 100 do
    let s = Lodge_selection.sample_beta ~alpha:1.0 ~beta:1.0 in
    check bool "beta sample >= 0" true (s >= 0.0);
    check bool "beta sample <= 1" true (s <= 1.0)
  done

let test_sample_beta_skew_high_alpha () =
  (* High alpha = skewed toward 1 *)
  let samples = List.init 100 (fun _ ->
    Lodge_selection.sample_beta ~alpha:10.0 ~beta:1.0
  ) in
  let mean = List.fold_left (+.) 0.0 samples /. 100.0 in
  (* With alpha=10, beta=1, expected mean is 10/11 ≈ 0.91 *)
  check bool "mean > 0.7 for high alpha" true (mean > 0.7)

let test_sample_beta_skew_high_beta () =
  (* High beta = skewed toward 0 *)
  let samples = List.init 100 (fun _ ->
    Lodge_selection.sample_beta ~alpha:1.0 ~beta:10.0
  ) in
  let mean = List.fold_left (+.) 0.0 samples /. 100.0 in
  (* With alpha=1, beta=10, expected mean is 1/11 ≈ 0.09 *)
  check bool "mean < 0.3 for high beta" true (mean < 0.3)

let test_sample_beta_clamp_minimum () =
  (* Very small alpha/beta should be clamped to 0.1 *)
  let _ = Lodge_selection.sample_beta ~alpha:0.01 ~beta:0.01 in
  (* Should not crash *)
  check bool "handles small alpha/beta" true true

(** {1 Starvation Bonus Tests} *)

let test_starvation_bonus_zero_ticks () =
  let bonus = Lodge_selection.starvation_bonus ~ticks:0 in
  check (float 0.01) "zero ticks = zero bonus" 0.0 bonus

let test_starvation_bonus_logarithmic () =
  let b6 = Lodge_selection.starvation_bonus ~ticks:6 in
  let b12 = Lodge_selection.starvation_bonus ~ticks:12 in
  let b24 = Lodge_selection.starvation_bonus ~ticks:24 in
  let b48 = Lodge_selection.starvation_bonus ~ticks:48 in
  (* Logarithmic growth: each doubling adds less *)
  check bool "6 ticks bonus > 0" true (b6 > 0.0);
  check bool "12 > 6" true (b12 > b6);
  check bool "24 > 12" true (b24 > b12);
  check bool "48 > 24" true (b48 > b24);
  (* But growth should slow down (logarithmic not linear) *)
  let delta_6_12 = b12 -. b6 in
  let delta_24_48 = b48 -. b24 in
  check bool "growth slows (log)" true (delta_24_48 < delta_6_12 *. 1.5)

let test_starvation_bonus_bounded () =
  (* Even after 1000 ticks, bonus should be reasonable *)
  let b1000 = Lodge_selection.starvation_bonus ~ticks:1000 in
  check bool "1000 ticks bonus < 2.0" true (b1000 < 2.0)

(** {1 Stats Management Tests} *)

let test_init_agent () =
  Lodge_selection.init_agent "test-agent-1";
  let stats = Lodge_selection.get_stats "test-agent-1" in
  check string "name matches" "test-agent-1" stats.name;
  check (float 0.01) "default alpha" 1.0 stats.alpha;
  check (float 0.01) "default beta" 1.0 stats.beta;
  check int "initial selections" 0 stats.selections

let test_record_selection () =
  Lodge_selection.init_agent "test-agent-2";
  let before = Lodge_selection.get_stats "test-agent-2" in
  let before_selections = before.selections in
  Lodge_selection.record_selection ~agent_name:"test-agent-2";
  let after = Lodge_selection.get_stats "test-agent-2" in
  check int "selections incremented" (before_selections + 1) after.selections;
  check bool "last_selected_at updated" true (after.last_selected_at > 0.0)

let test_record_action_post () =
  Lodge_selection.init_agent "test-agent-3";
  let before = Lodge_selection.get_stats "test-agent-3" in
  let before_posts = before.posts_created in
  Lodge_selection.record_action ~agent_name:"test-agent-3" ~action:`Post;
  let after = Lodge_selection.get_stats "test-agent-3" in
  check int "posts incremented" (before_posts + 1) after.posts_created

let test_record_action_skip () =
  Lodge_selection.init_agent "test-agent-4";
  let before = Lodge_selection.get_stats "test-agent-4" in
  let before_skips = before.skips in
  Lodge_selection.record_action ~agent_name:"test-agent-4" ~action:`Skip;
  let after = Lodge_selection.get_stats "test-agent-4" in
  check int "skips incremented" (before_skips + 1) after.skips

(** {1 Vote Feedback Tests} *)

let test_record_vote_pending () =
  Lodge_selection.init_agent "test-agent-5";
  Lodge_selection.record_vote ~agent_name:"test-agent-5" ~direction:`Up;
  Lodge_selection.record_vote ~agent_name:"test-agent-5" ~direction:`Up;
  Lodge_selection.record_vote ~agent_name:"test-agent-5" ~direction:`Down;
  (* Votes are pending until flush *)
  let before = Lodge_selection.get_stats "test-agent-5" in
  check int "total_votes_up unchanged before flush" 0 before.total_votes_up;
  Lodge_selection.flush_pending_votes ();
  let after = Lodge_selection.get_stats "test-agent-5" in
  check int "total_votes_up after flush" 2 after.total_votes_up;
  check int "total_votes_down after flush" 1 after.total_votes_down

let test_vote_updates_alpha_beta () =
  Lodge_selection.init_agent "test-agent-6";
  let before = Lodge_selection.get_stats "test-agent-6" in
  let before_alpha = before.alpha in
  (* Record all upvotes (100% success rate) *)
  for _ = 1 to 10 do
    Lodge_selection.record_vote ~agent_name:"test-agent-6" ~direction:`Up
  done;
  Lodge_selection.flush_pending_votes ();
  let after = Lodge_selection.get_stats "test-agent-6" in
  (* Alpha should increase with positive votes *)
  check bool "alpha increased" true (after.alpha > before_alpha)

(** {1 Selection Algorithm Tests} *)

let test_select_empty_agents () =
  let results = Lodge_selection.select_with_feedback
    ~agents:[]
    ~max_n:3
    ~pending_triggers:[]
    ~tick_interval_s:14400.0
  in
  check int "empty agents = empty selection" 0 (List.length results)

let test_select_respects_max_n () =
  let agents = ["agent-a"; "agent-b"; "agent-c"; "agent-d"; "agent-e"] in
  List.iter Lodge_selection.init_agent agents;
  let results = Lodge_selection.select_with_feedback
    ~agents
    ~max_n:2
    ~pending_triggers:[]
    ~tick_interval_s:14400.0
  in
  check int "respects max_n" 2 (List.length results)

let test_select_mentioned_priority () =
  let agents = ["agent-x"; "agent-y"; "agent-z"] in
  List.iter Lodge_selection.init_agent agents;
  let triggers = [
    ("agent-y", Lodge_selection.Mentioned "test mention")
  ] in
  let results = Lodge_selection.select_with_feedback
    ~agents
    ~max_n:2
    ~pending_triggers:triggers
    ~tick_interval_s:14400.0
  in
  (* Mentioned agent should be first *)
  check bool "mentioned agent selected" true
    (List.exists (fun r -> r.Lodge_selection.agent_name = "agent-y") results);
  let first = List.hd results in
  check string "mentioned agent is first" "agent-y" first.agent_name

let test_select_content_alert_priority () =
  let agents = ["agent-p"; "agent-q"; "agent-r"] in
  List.iter Lodge_selection.init_agent agents;
  let triggers = [
    ("agent-r", Lodge_selection.ContentAlert "urgent content")
  ] in
  let results = Lodge_selection.select_with_feedback
    ~agents
    ~max_n:2
    ~pending_triggers:triggers
    ~tick_interval_s:14400.0
  in
  check bool "content alert agent selected" true
    (List.exists (fun r -> r.Lodge_selection.agent_name = "agent-r") results)

(** {1 Selection Entropy Tests} *)

let test_selection_entropy_empty () =
  (* Clear any existing stats for entropy calculation *)
  let entropy = Lodge_selection.selection_entropy () in
  (* With some agents having selections, entropy should be positive *)
  check bool "entropy is non-negative" true (entropy >= 0.0)

(** {1 Test Runner} *)

let () =
  run "Lodge_selection" [
    "beta_sampling", [
      test_case "sample in [0,1] range" `Quick test_sample_beta_range;
      test_case "high alpha skew" `Quick test_sample_beta_skew_high_alpha;
      test_case "high beta skew" `Quick test_sample_beta_skew_high_beta;
      test_case "clamp minimum" `Quick test_sample_beta_clamp_minimum;
    ];
    "starvation_bonus", [
      test_case "zero ticks" `Quick test_starvation_bonus_zero_ticks;
      test_case "logarithmic growth" `Quick test_starvation_bonus_logarithmic;
      test_case "bounded growth" `Quick test_starvation_bonus_bounded;
    ];
    "stats_management", [
      test_case "init_agent" `Quick test_init_agent;
      test_case "record_selection" `Quick test_record_selection;
      test_case "record_action post" `Quick test_record_action_post;
      test_case "record_action skip" `Quick test_record_action_skip;
    ];
    "vote_feedback", [
      test_case "pending votes" `Quick test_record_vote_pending;
      test_case "alpha/beta update" `Quick test_vote_updates_alpha_beta;
    ];
    "selection", [
      test_case "empty agents" `Quick test_select_empty_agents;
      test_case "respects max_n" `Quick test_select_respects_max_n;
      test_case "mentioned priority" `Quick test_select_mentioned_priority;
      test_case "content alert priority" `Quick test_select_content_alert_priority;
    ];
    "monitoring", [
      test_case "selection entropy" `Quick test_selection_entropy_empty;
    ];
  ]
