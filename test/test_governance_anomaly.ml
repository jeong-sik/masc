(** Tests for Governance_anomaly — behavioral baseline & deviation detection. *)

open Alcotest
open Masc_mcp

let agent_id = "test-agent"

let make_tmpdir () =
  let tmpdir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-anomaly-test-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir tmpdir 0o755;
  tmpdir

let cleanup_tmpdir dir =
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      try Unix.rmdir path with Unix.Unix_error _ -> ()
    end else
      try Sys.remove path with Sys_error _ -> ()
  in
  rm_rf dir

(** Generate [count] audit entries spaced [spacing_sec] apart,
    ending at [end_ts]. All share [agent_id]. *)
let gen_entries ~end_ts ~spacing_sec ~count ~tool_names ~outcomes ~token_counts =
  List.init count (fun i ->
    let timestamp = end_ts -. (float_of_int (count - 1 - i) *. spacing_sec) in
    let tool_name = List.nth tool_names (i mod List.length tool_names) in
    let outcome = List.nth outcomes (i mod List.length outcomes) in
    let token_count = List.nth token_counts (i mod List.length token_counts) in
    {
      Audit_log.timestamp;
      agent_id;
      action = Audit_log.ToolCall tool_name;
      room_id = None;
      details = `Null;
      outcome;
      cost_estimate = None;
      token_count = Some token_count;
      trace_id = None;
    })

let write_entries config entries =
  List.iter (Audit_log.append_entry config) entries

(* ── Tests ──────────────────────────────────────────────────── *)

let test_build_profile_insufficient_entries () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = make_tmpdir () in
  Fun.protect
    ~finally:(fun () -> cleanup_tmpdir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let entries = gen_entries ~end_ts:(Unix.gettimeofday ()) ~spacing_sec:3600.
        ~count:2 ~tool_names:["read"] ~outcomes:[Audit_log.Success] ~token_counts:[100] in
      write_entries config entries;
      match Governance_anomaly.build_profile ~config ~agent_id ~window_days:1 with
      | None -> ()
      | Some _ -> fail "expected None with < 3 entries")

let test_build_profile_success () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = make_tmpdir () in
  Fun.protect
    ~finally:(fun () -> cleanup_tmpdir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let now = Unix.gettimeofday () in
      let entries = gen_entries ~end_ts:now ~spacing_sec:3600.
        ~count:10 ~tool_names:["read"; "write"] ~outcomes:[Audit_log.Success]
        ~token_counts:[100] in
      write_entries config entries;
      match Governance_anomaly.build_profile ~config ~agent_id ~window_days:1 with
      | None -> fail "expected Some profile"
      | Some p ->
          check string "agent_id" agent_id p.agent_id;
          check int "sample_count" 10 p.sample_count;
          check int "window_days" 1 p.window_days;
          check bool "has activity_volume mean" true (p.activity_volume.mean > 0.0);
          check bool "has tool_diversity mean" true (p.tool_diversity.mean >= 0.0);
          check bool "has failure_rate mean" true (p.failure_rate.mean >= 0.0);
          check int "hourly_dist length" 24 (Array.length p.hourly_dist))

let test_detect_deviations () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = make_tmpdir () in
  Fun.protect
    ~finally:(fun () -> cleanup_tmpdir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let now = Unix.gettimeofday () in
      (* baseline: 10 entries, 1 per hour, all Success, single tool *)
      let baseline = gen_entries ~end_ts:now ~spacing_sec:3600.
        ~count:10 ~tool_names:["read"] ~outcomes:[Audit_log.Success] ~token_counts:[100] in
      write_entries config baseline;
      let profile =
        match Governance_anomaly.build_profile ~config ~agent_id ~window_days:1 with
        | None -> fail "expected profile"
        | Some p -> p
      in
      (* recent burst: 20 entries in 1 hour -> much higher activity volume *)
      let recent = gen_entries ~end_ts:now ~spacing_sec:180.
        ~count:20 ~tool_names:["read"] ~outcomes:[Audit_log.Success] ~token_counts:[100] in
      let deviations = Governance_anomaly.detect_deviations ~profile ~entries:recent ~threshold:1.0 in
      check bool "detected at least one deviation" true (List.length deviations > 0);
      let has_activity =
        List.exists (fun d -> String.equal d.Governance_anomaly.dimension "activity_volume") deviations
      in
      check bool "activity_volume deviated" true has_activity)

let test_save_load_profile_roundtrip () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = make_tmpdir () in
  Fun.protect
    ~finally:(fun () -> cleanup_tmpdir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let now = Unix.gettimeofday () in
      let entries = gen_entries ~end_ts:now ~spacing_sec:3600.
        ~count:10 ~tool_names:["read"; "write"] ~outcomes:[Audit_log.Success; Audit_log.Failure "err"]
        ~token_counts:[100] in
      write_entries config entries;
      let profile =
        match Governance_anomaly.build_profile ~config ~agent_id ~window_days:1 with
        | None -> fail "expected profile"
        | Some p -> p
      in
      Governance_anomaly.save_profile ~base_path:dir profile;
      let loaded =
        match Governance_anomaly.load_profile ~base_path:dir ~agent_id with
        | None -> fail "expected loaded profile"
        | Some p -> p
      in
      check string "agent_id roundtrip" profile.agent_id loaded.agent_id;
      check int "sample_count roundtrip" profile.sample_count loaded.sample_count;
      check (float 0.001) "activity_volume mean" profile.activity_volume.mean loaded.activity_volume.mean;
      check (float 0.001) "activity_volume stddev" profile.activity_volume.stddev loaded.activity_volume.stddev;
      check (float 0.001) "tool_diversity mean" profile.tool_diversity.mean loaded.tool_diversity.mean;
      check (float 0.001) "failure_rate mean" profile.failure_rate.mean loaded.failure_rate.mean;
      check int "hourly_dist length" 24 (Array.length loaded.hourly_dist))

let test_check_agent_pipeline () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = make_tmpdir () in
  Fun.protect
    ~finally:(fun () -> cleanup_tmpdir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let now = Unix.gettimeofday () in
      (* Dense entries (5-min spacing, all within 45 min) produce a single batch,
         so stddev = 0 and z_score = 0 -> no deviations. *)
      let entries = gen_entries ~end_ts:now ~spacing_sec:300.
        ~count:10 ~tool_names:["read"] ~outcomes:[Audit_log.Success] ~token_counts:[100] in
      write_entries config entries;
      match Governance_anomaly.check_agent ~config ~agent_id ~window_days:1 ~threshold:1.5 with
      | None -> fail "expected report"
      | Some report ->
          check string "report agent_id" agent_id report.Governance_anomaly.agent_id;
          check bool "no deviations" true (report.Governance_anomaly.deviations = []);
          check string "overall risk low" "low"
            (Governance_pipeline_types.risk_level_to_string report.Governance_anomaly.overall_risk))

let test_detect_deviations_empty_entries () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = make_tmpdir () in
  Fun.protect
    ~finally:(fun () -> cleanup_tmpdir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let now = Unix.gettimeofday () in
      let entries = gen_entries ~end_ts:now ~spacing_sec:3600.
        ~count:10 ~tool_names:["read"] ~outcomes:[Audit_log.Success] ~token_counts:[100] in
      write_entries config entries;
      let profile =
        match Governance_anomaly.build_profile ~config ~agent_id ~window_days:1 with
        | None -> fail "expected profile"
        | Some p -> p
      in
      let deviations = Governance_anomaly.detect_deviations ~profile ~entries:[] ~threshold:1.0 in
      check bool "empty entries -> no deviations" true (deviations = []))

let test_detect_deviations_no_token_volume () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = make_tmpdir () in
  Fun.protect
    ~finally:(fun () -> cleanup_tmpdir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let now = Unix.gettimeofday () in
      (* No token_count logged -> profile.token_volume = None *)
      let entries = gen_entries ~end_ts:now ~spacing_sec:3600.
        ~count:10 ~tool_names:["read"] ~outcomes:[Audit_log.Success] ~token_counts:[100] in
      let entries = List.map (fun e -> { e with Audit_log.token_count = None }) entries in
      write_entries config entries;
      let profile =
        match Governance_anomaly.build_profile ~config ~agent_id ~window_days:1 with
        | None -> fail "expected profile"
        | Some p -> p
      in
      check bool "token_volume is None" true (profile.Governance_anomaly.token_volume = None);
      (* Even with wildly different recent entries, token_volume dimension is skipped. *)
      let recent = gen_entries ~end_ts:now ~spacing_sec:180.
        ~count:20 ~tool_names:["read"] ~outcomes:[Audit_log.Success] ~token_counts:[10000] in
      let deviations = Governance_anomaly.detect_deviations ~profile ~entries:recent ~threshold:1.0 in
      let has_token =
        List.exists (fun d -> String.equal d.Governance_anomaly.dimension "token_volume") deviations
      in
      check bool "token_volume not checked when None" false has_token)

let test_load_profile_missing () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = make_tmpdir () in
  Fun.protect
    ~finally:(fun () -> cleanup_tmpdir dir)
    (fun () ->
      match Governance_anomaly.load_profile ~base_path:dir ~agent_id:"no-such-agent" with
      | None -> ()
      | Some _ -> fail "expected None for missing profile")

let test_check_agent_insufficient_entries () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = make_tmpdir () in
  Fun.protect
    ~finally:(fun () -> cleanup_tmpdir dir)
    (fun () ->
      let config = Coord.default_config dir in
      let now = Unix.gettimeofday () in
      let entries = gen_entries ~end_ts:now ~spacing_sec:3600.
        ~count:2 ~tool_names:["read"] ~outcomes:[Audit_log.Success] ~token_counts:[100] in
      write_entries config entries;
      match Governance_anomaly.check_agent ~config ~agent_id ~window_days:1 ~threshold:1.5 with
      | None -> ()
      | Some _ -> fail "expected None with < 3 entries")

let () =
  run "Governance_anomaly"
    [
      ( "baseline",
        [
          test_case "build_profile returns None when insufficient entries" `Quick
            test_build_profile_insufficient_entries;
          test_case "build_profile computes stats" `Quick test_build_profile_success;
        ] );
      ( "deviation",
        [
          test_case "detect_deviations flags burst activity" `Quick test_detect_deviations;
          test_case "detect_deviations empty entries" `Quick test_detect_deviations_empty_entries;
          test_case "detect_deviations skips token_volume when None" `Quick test_detect_deviations_no_token_volume;
        ] );
      ( "persistence",
        [
          test_case "save/load profile roundtrip" `Quick test_save_load_profile_roundtrip;
          test_case "load_profile returns None when missing" `Quick test_load_profile_missing;
        ] );
      ( "pipeline",
        [
          test_case "check_agent produces report" `Quick test_check_agent_pipeline;
          test_case "check_agent returns None when insufficient entries" `Quick test_check_agent_insufficient_entries;
        ] );
    ]
