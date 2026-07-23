(** Tests for Thompson_sampling module — Beta-prior bookkeeping *)

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

let test_record_action_post () =
  let before = Thompson_sampling.get_stats "test-agent-3" in
  let before_posts = before.posts_created in
  Thompson_sampling.record_action ~agent_name:"test-agent-3" ~action:`Post;
  let after = Thompson_sampling.get_stats "test-agent-3" in
  check int "posts incremented" (before_posts + 1) after.posts_created

let test_record_action_skip () =
  let before = Thompson_sampling.get_stats "test-agent-4" in
  let before_skips = before.skips in
  Thompson_sampling.record_action ~agent_name:"test-agent-4" ~action:`Skip;
  let after = Thompson_sampling.get_stats "test-agent-4" in
  check int "skips incremented" (before_skips + 1) after.skips

(** {1 Quality Signal Tests (Phase 3)} *)

module Pv = Thompson_sampling
let float_eq ?(eps = 0.001) a b = Float.abs (a -. b) < eps

(* Reset agent stats for test isolation *)
let fresh_agent name =
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
  Thompson_sampling.record_action ~agent_name:agent_b ~action:`Post;
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
    "stats_management", [
      test_case "record_action post" `Quick test_record_action_post;
      test_case "record_action skip" `Quick test_record_action_skip;
    ];
    "quality_signal", [
      test_case "pass boosts alpha" `Quick test_quality_pass_boosts_alpha;
      test_case "warn nudges beta" `Quick test_quality_warn_nudges_beta;
      test_case "fail penalizes beta" `Quick test_quality_fail_penalizes_beta;
      test_case "signal floor" `Quick test_quality_signal_floor;
      test_case "cumulative signals" `Quick test_quality_cumulative;
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
