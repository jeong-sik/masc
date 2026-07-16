(** Tests for Thompson_sampling module — Thompson Sampling with fairness *)

open Alcotest
open Masc

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

(** {1 Beta Distribution Sampling Tests} *)

let test_sample_beta_range () =
  (* Run multiple samples and verify they fall in [0, 1] *)
  for _ = 1 to 100 do
    let s = Thompson_sampling.sample_beta ~alpha:1.0 ~beta:1.0 in
    check bool "beta sample >= 0" true (s >= 0.0);
    check bool "beta sample <= 1" true (s <= 1.0)
  done

let test_sample_beta_skew_high_alpha () =
  (* High alpha = skewed toward 1 *)
  let samples = List.init 100 (fun _ ->
    Thompson_sampling.sample_beta ~alpha:10.0 ~beta:1.0
  ) in
  let mean = List.fold_left (+.) 0.0 samples /. 100.0 in
  (* With alpha=10, beta=1, expected mean is 10/11 ≈ 0.91 *)
  check bool "mean > 0.7 for high alpha" true (mean > 0.7)

let test_sample_beta_skew_high_beta () =
  (* High beta = skewed toward 0 *)
  let samples = List.init 100 (fun _ ->
    Thompson_sampling.sample_beta ~alpha:1.0 ~beta:10.0
  ) in
  let mean = List.fold_left (+.) 0.0 samples /. 100.0 in
  (* With alpha=1, beta=10, expected mean is 1/11 ≈ 0.09 *)
  check bool "mean < 0.3 for high beta" true (mean < 0.3)

let test_sample_beta_clamp_minimum () =
  (* Very small alpha/beta should be clamped to 0.1 *)
  let _ = Thompson_sampling.sample_beta ~alpha:0.01 ~beta:0.01 in
  (* Should not crash *)
  ()

(** {1 Starvation Bonus Tests} *)

let test_starvation_bonus_zero_ticks () =
  let bonus = Thompson_sampling.starvation_bonus ~ticks:0 in
  check (float 0.01) "zero ticks = zero bonus" 0.0 bonus

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

let test_starvation_bonus_bounded () =
  (* Even after 1000 ticks, bonus should be reasonable *)
  let b1000 = Thompson_sampling.starvation_bonus ~ticks:1000 in
  check bool "1000 ticks bonus < 2.0" true (b1000 < 2.0)

(** {1 Stats Management Tests} *)

let test_init_agent () =
  Thompson_sampling.init_agent "test-agent-1";
  let stats = Thompson_sampling.get_stats "test-agent-1" in
  check string "name matches" "test-agent-1" stats.name;
  check (float 0.01) "default alpha" 1.0 stats.alpha;
  check (float 0.01) "default beta" 1.0 stats.beta;
  check int "initial selections" 0 stats.selections

let test_record_selection () =
  Thompson_sampling.init_agent "test-agent-2";
  let before = Thompson_sampling.get_stats "test-agent-2" in
  let before_selections = before.selections in
  Thompson_sampling.record_selection ~agent_name:"test-agent-2";
  let after = Thompson_sampling.get_stats "test-agent-2" in
  check int "selections incremented" (before_selections + 1) after.selections;
  check bool "last_selected_at updated" true (after.last_selected_at > 0.0)

let test_record_action_post () =
  Thompson_sampling.init_agent "test-agent-3";
  let before = Thompson_sampling.get_stats "test-agent-3" in
  let before_posts = before.posts_created in
  Thompson_sampling.record_action ~agent_name:"test-agent-3" ~action:`Post;
  let after = Thompson_sampling.get_stats "test-agent-3" in
  check int "posts incremented" (before_posts + 1) after.posts_created

let test_record_action_skip () =
  Thompson_sampling.init_agent "test-agent-4";
  let before = Thompson_sampling.get_stats "test-agent-4" in
  let before_skips = before.skips in
  Thompson_sampling.record_action ~agent_name:"test-agent-4" ~action:`Skip;
  let after = Thompson_sampling.get_stats "test-agent-4" in
  check int "skips incremented" (before_skips + 1) after.skips

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

(** {1 Selection Algorithm Tests} *)

let test_select_empty_agents () =
  let results = Thompson_sampling.select_with_feedback
    ~agents:[]
    ~max_n:3
    ~pending_triggers:[]
    ~tick_interval_s:14400.0
    ()
  in
  check int "empty agents = empty selection" 0 (List.length results)

let test_select_respects_max_n () =
  let agents = ["agent-a"; "agent-b"; "agent-c"; "agent-d"; "agent-e"] in
  List.iter Thompson_sampling.init_agent agents;
  let results = Thompson_sampling.select_with_feedback
    ~agents
    ~max_n:2
    ~pending_triggers:[]
    ~tick_interval_s:14400.0
    ()
  in
  check int "respects max_n" 2 (List.length results)

let test_select_mentioned_priority () =
  let agents = ["agent-x"; "agent-y"; "agent-z"] in
  List.iter Thompson_sampling.init_agent agents;
  let triggers = [
    ("agent-y", Thompson_sampling.Mentioned "test mention")
  ] in
  let results = Thompson_sampling.select_with_feedback
    ~agents
    ~max_n:2
    ~pending_triggers:triggers
    ~tick_interval_s:14400.0
    ()
  in
  (* Mentioned agent should be first *)
  check bool "mentioned agent selected" true
    (List.exists (fun r -> r.Thompson_sampling.agent_name = "agent-y") results);
  let first = List.hd results in
  check string "mentioned agent is first" "agent-y" first.agent_name

let test_select_content_alert_priority () =
  let agents = ["agent-p"; "agent-q"; "agent-r"] in
  List.iter Thompson_sampling.init_agent agents;
  let triggers = [
    ("agent-r", Thompson_sampling.ContentAlert "urgent content")
  ] in
  let results = Thompson_sampling.select_with_feedback
    ~agents
    ~max_n:2
    ~pending_triggers:triggers
    ~tick_interval_s:14400.0
    ()
  in
  check bool "content alert agent selected" true
    (List.exists (fun r -> r.Thompson_sampling.agent_name = "agent-r") results)

let test_stronger_trigger_replaces_weaker_duplicate () =
  let agents = ["agent-dupe"] in
  List.iter Thompson_sampling.init_agent agents;
  let triggers = [
    ("agent-dupe", Thompson_sampling.ContentAlert "alert");
    ("agent-dupe", Thompson_sampling.Mentioned "mention");
  ] in
  let results = Thompson_sampling.select_with_feedback
    ~agents
    ~max_n:1
    ~pending_triggers:triggers
    ~tick_interval_s:14400.0
    ()
  in
  let selected = List.hd results in
  match selected.Thompson_sampling.trigger with
  | Thompson_sampling.Mentioned _ ->
      ()
  | _ ->
      fail "expected Mentioned trigger to override ContentAlert"

let test_stronger_trigger_uses_winner_order () =
  let agents = ["agent-a"; "agent-b"] in
  List.iter Thompson_sampling.init_agent agents;
  let triggers = [
    ("agent-a", Thompson_sampling.ContentAlert "alert-first");
    ("agent-b", Thompson_sampling.Mentioned "mention-b");
    ("agent-a", Thompson_sampling.Mentioned "mention-a");
  ] in
  let results = Thompson_sampling.select_with_feedback
    ~agents
    ~max_n:2
    ~pending_triggers:triggers
    ~tick_interval_s:14400.0
    ()
  in
  let first = List.hd results in
  check string "winner ordering follows stronger trigger position" "agent-b" first.agent_name

(** {1 Quality Signal Tests (Phase 3)} *)

module Pv = Thompson_sampling
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

let test_quality_pass_boosts_alpha () =
  let s = fresh_agent "qs-pass" in
  let orig_alpha = s.alpha in
  let orig_beta = s.beta in
  Thompson_sampling.record_quality_signal ~agent_name:"qs-pass" ~verdict:Pv.Pass;
  check bool "alpha +0.3" true (float_eq s.alpha (orig_alpha +. 0.3));
  check bool "beta unchanged" true (float_eq s.beta orig_beta)

let test_quality_warn_nudges_beta () =
  let s = fresh_agent "qs-warn" in
  let orig_alpha = s.alpha in
  let orig_beta = s.beta in
  Thompson_sampling.record_quality_signal ~agent_name:"qs-warn"
    ~verdict:(Pv.Warn "filler_content");
  check bool "alpha unchanged" true (float_eq s.alpha orig_alpha);
  check bool "beta +0.1" true (float_eq s.beta (orig_beta +. 0.1))

let test_quality_fail_penalizes_beta () =
  let s = fresh_agent "qs-fail" in
  let orig_alpha = s.alpha in
  let orig_beta = s.beta in
  Thompson_sampling.record_quality_signal ~agent_name:"qs-fail"
    ~verdict:(Pv.Fail "too_short");
  check bool "alpha unchanged" true (float_eq s.alpha orig_alpha);
  check bool "beta +0.5" true (float_eq s.beta (orig_beta +. 0.5))

let test_quality_signal_floor () =
  let s = fresh_agent "qs-floor" in
  s.alpha <- 0.05;
  s.beta <- 0.05;
  Thompson_sampling.record_quality_signal ~agent_name:"qs-floor"
    ~verdict:(Pv.Fail "bad");
  check bool "alpha >= 0.1" true (s.alpha >= 0.1);
  check bool "beta >= 0.1" true (s.beta >= 0.1)

let test_quality_cumulative () =
  let s = fresh_agent "qs-cumul" in
  Thompson_sampling.record_quality_signal ~agent_name:"qs-cumul" ~verdict:Pv.Pass;
  Thompson_sampling.record_quality_signal ~agent_name:"qs-cumul" ~verdict:Pv.Pass;
  Thompson_sampling.record_quality_signal ~agent_name:"qs-cumul" ~verdict:Pv.Pass;
  check bool "3x Pass → alpha ~1.9" true (float_eq s.alpha 1.9);
  check bool "beta unchanged" true (float_eq s.beta 1.0)

(** {1 Selection Entropy Tests} *)

let test_selection_entropy_empty () =
  (* Clear any existing stats for entropy calculation *)
  let entropy = Thompson_sampling.selection_entropy () in
  (* With some agents having selections, entropy should be positive *)
  check bool "entropy is non-negative" true (entropy >= 0.0)

(** {1 Persistence Tests} *)

let find_stats_row name rows =
  let open Yojson.Safe.Util in
  List.find_opt
    (fun json -> json |> member "name" |> to_string = name)
    rows

let stats_path_for_base_path base_path =
  let masc_dir = Workspace_utils.masc_dir_from_base_path ~base_path in
  Fs_compat.mkdir_p masc_dir;
  Filename.concat masc_dir "autonomy_stats.jsonl"

let stats_rows path =
  if Fs_compat.file_exists path then Fs_compat.load_jsonl path else []

let test_persistence_loads_and_saves_pending_votes () =
  with_temp_dir "thompson-persistence" @@ fun base_path ->
  let path = stats_path_for_base_path base_path in
  let loaded_agent = "persist-load-agent" in
  let pending_agent = "persist-pending-agent" in
  let existing =
    `Assoc
      [
        ("name", `String loaded_agent);
        ("alpha", `Float 3.0);
        ("beta", `Float 2.0);
        ("selections", `Int 7);
        ("last_selected_at", `Float 10.0);
        ("total_votes_up", `Int 4);
        ("total_votes_down", `Int 1);
        ("posts_created", `Int 2);
        ("comments_created", `Int 3);
        ("skips", `Int 1);
        ("guard_penalties_total", `Int 0);
        ("updated_at", `Float 11.0);
      ]
  in
  Fs_compat.save_file path (Yojson.Safe.to_string existing ^ "\n");
  Thompson_sampling.set_base_path base_path;
  Thompson_sampling.load_stats ();
  let loaded = Thompson_sampling.get_stats loaded_agent in
  check (float 0.01) "loaded alpha" 3.0 loaded.alpha;
  check int "loaded selections" 7 loaded.selections;
  Thompson_sampling.record_vote ~agent_name:pending_agent ~direction:`Up;
  let rows = Fs_compat.load_jsonl path in
  match find_stats_row pending_agent rows with
  | Some json ->
      let open Yojson.Safe.Util in
      check int "pending vote persisted" 1
        (json |> member "total_votes_up" |> to_int)
  | None -> fail "pending vote row not persisted"

let test_persistence_load_skips_corrupt_and_nameless_rows () =
  with_temp_dir "thompson-corrupt-persistence" @@ fun base_path ->
  let path = stats_path_for_base_path base_path in
  let valid_agent = "persist-valid-after-corrupt" in
  let valid =
    `Assoc
      [
        ("name", `String valid_agent);
        ("alpha", `Float 4.0);
        ("beta", `Float 1.5);
        ("selections", `Int 9);
        ("last_selected_at", `Float 12.0);
        ("total_votes_up", `Int 5);
        ("total_votes_down", `Int 2);
        ("posts_created", `Int 1);
        ("comments_created", `Int 0);
        ("skips", `Int 0);
        ("guard_penalties_total", `Int 0);
        ("updated_at", `Float 13.0);
      ]
  in
  let nameless =
    `Assoc
      [
        ("alpha", `Float 99.0);
        ("beta", `Float 99.0);
        ("selections", `Int 99);
      ]
  in
  let schema_mismatch =
    `Assoc
      [
        ("name", `String "persist-schema-mismatch");
        ("score", `Float 99.0);
        ("selections", `Int 99);
      ]
  in
  Fs_compat.save_file path
    (String.concat "\n"
       [
         "{not-json";
         Yojson.Safe.to_string nameless;
         Yojson.Safe.to_string schema_mismatch;
         Yojson.Safe.to_string valid;
         "";
       ]);
  Thompson_sampling.set_base_path base_path;
  Thompson_sampling.load_stats ();
  let loaded = Thompson_sampling.get_stats valid_agent in
  check (float 0.01) "valid row loaded despite corrupt file prefix" 4.0 loaded.alpha;
  check int "valid row selections loaded" 9 loaded.selections;
  let has_empty_name =
    Thompson_sampling.get_all_stats ()
    |> List.exists (fun (s : Thompson_sampling.agent_stats) -> String.equal s.name "")
  in
  check bool "nameless schema row skipped" false has_empty_name;
  let loaded_names =
    Thompson_sampling.get_all_stats ()
    |> List.map (fun (s : Thompson_sampling.agent_stats) -> s.name)
  in
  check bool "schema mismatch row skipped" false
    (List.mem "persist-schema-mismatch" loaded_names)

let test_persistence_base_path_switch_replaces_state () =
  with_temp_dir "thompson-persistence-a" @@ fun base_a ->
  with_temp_dir "thompson-persistence-b" @@ fun base_b ->
  let path_a = stats_path_for_base_path base_a in
  let path_b = stats_path_for_base_path base_b in
  let agent_a = "persist-base-a-agent" in
  let pending_a = "persist-base-a-pending" in
  let agent_b = "persist-base-b-agent" in
  let existing_a =
    `Assoc
      [
        ("name", `String agent_a);
        ("alpha", `Float 5.0);
        ("beta", `Float 1.0);
        ("selections", `Int 3);
        ("last_selected_at", `Float 20.0);
        ("total_votes_up", `Int 2);
        ("total_votes_down", `Int 0);
        ("posts_created", `Int 0);
        ("comments_created", `Int 0);
        ("skips", `Int 0);
        ("guard_penalties_total", `Int 0);
        ("updated_at", `Float 21.0);
      ]
  in
  Fs_compat.save_file path_a (Yojson.Safe.to_string existing_a ^ "\n");
  Thompson_sampling.set_base_path base_a;
  Thompson_sampling.load_stats ();
  check bool "base A row loaded" true
    (Option.is_some (find_stats_row agent_a (stats_rows path_a)));
  Thompson_sampling.record_vote ~agent_name:pending_a ~direction:`Up;
  Thompson_sampling.set_base_path base_b;
  Thompson_sampling.load_stats ();
  let loaded_names =
    Thompson_sampling.get_all_stats ()
    |> List.map (fun (s : Thompson_sampling.agent_stats) -> s.name)
  in
  check bool "base A loaded row cleared after switching base" false
    (List.mem agent_a loaded_names);
  check bool "base A pending row cleared after switching base" false
    (List.mem pending_a loaded_names);
  Thompson_sampling.record_selection ~agent_name:agent_b;
  let rows_b = stats_rows path_b in
  check bool "base B file contains only B row" true
    (Option.is_some (find_stats_row agent_b rows_b));
  check bool "base B file does not inherit A loaded row" false
    (Option.is_some (find_stats_row agent_a rows_b));
  check bool "base B file does not inherit A pending row" false
    (Option.is_some (find_stats_row pending_a rows_b))

(** {1 Test Runner} *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "Thompson_sampling" [
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
      test_case "stronger trigger overrides weaker duplicate" `Quick test_stronger_trigger_replaces_weaker_duplicate;
      test_case "stronger trigger uses winner order" `Quick test_stronger_trigger_uses_winner_order;
    ];
    "quality_signal", [
      test_case "pass boosts alpha" `Quick test_quality_pass_boosts_alpha;
      test_case "warn nudges beta" `Quick test_quality_warn_nudges_beta;
      test_case "fail penalizes beta" `Quick test_quality_fail_penalizes_beta;
      test_case "signal floor" `Quick test_quality_signal_floor;
      test_case "cumulative signals" `Quick test_quality_cumulative;
    ];
    "monitoring", [
      test_case "selection entropy" `Quick test_selection_entropy_empty;
    ];
    "persistence", [
      test_case "load stats and save pending votes" `Quick
        test_persistence_loads_and_saves_pending_votes;
      test_case "load skips corrupt and nameless rows" `Quick
        test_persistence_load_skips_corrupt_and_nameless_rows;
      test_case "base path switch replaces loaded state" `Quick
        test_persistence_base_path_switch_replaces_state;
    ];
  ]
