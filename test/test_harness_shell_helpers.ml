open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when String.trim root <> "" -> root
  | _ -> Sys.getcwd ()

let quote = Filename.quote

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

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

let run_bash ~cwd cmd =
  let out = Filename.temp_file "harness-shell-out" ".txt" in
  let err = Filename.temp_file "harness-shell-err" ".txt" in
  let wrapped =
    Printf.sprintf "cd %s && %s > %s 2> %s"
      (quote cwd) cmd (quote out) (quote err)
  in
  let code =
    Unix.create_process "/bin/bash"
      [| "/bin/bash"; "-lc"; wrapped |]
      Unix.stdin Unix.stdout Unix.stderr
    |> fun pid -> snd (Unix.waitpid [] pid)
    |> function
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255
  in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (code, stdout, stderr)

let split_nonempty_lines s =
  s
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    idx + nlen <= hlen
    && (String.sub haystack idx nlen = needle || loop (idx + 1))
  in
  nlen = 0 || loop 0

let test_server_bootstrap_temp_helpers () =
  with_temp_dir "harness-bootstrap-temp" (fun dir ->
      let script =
        Filename.concat (source_root ()) "scripts/harness/lib/server_bootstrap.sh"
      in
      let code, stdout, stderr =
        run_bash ~cwd:dir
          (Printf.sprintf
             "source %s; a=$(harness_mktemp_file masc-helper .log); b=$(harness_mktemp_file masc-helper .log); d=$(harness_mktemp_dir masc-helper-dir); printf '%%s\\n%%s\\n%%s\\n' \"$a\" \"$b\" \"$d\""
             (quote script))
      in
      if code <> 0 then
        failf "server_bootstrap helper command failed (%d): %s" code stderr;
      match split_nonempty_lines stdout with
      | [ first; second; dir_path ] ->
        check bool "first temp file exists" true (Sys.file_exists first);
        check bool "second temp file exists" true (Sys.file_exists second);
        check bool "temp dir exists" true (Sys.file_exists dir_path && Sys.is_directory dir_path);
        check bool "file suffix preserved" true (Filename.check_suffix first ".log");
        check bool "unique temp files" true (first <> second);
        check bool "template expanded in file path" false
          (contains_substring first "XXXXXX");
        check bool "template expanded in dir path" false
          (contains_substring dir_path "XXXXXX");
        rm_rf first;
        rm_rf second;
        rm_rf dir_path
      | lines ->
        failf "unexpected helper output:\n%s" (String.concat "\n" lines))

let test_mcp_jsonrpc_temp_helper () =
  with_temp_dir "harness-mcp-temp" (fun dir ->
      let script =
        Filename.concat (source_root ()) "scripts/harness/lib/mcp_jsonrpc.sh"
      in
      let code, stdout, stderr =
        run_bash ~cwd:dir
          (Printf.sprintf
             "source %s; f=$(mcp_mktemp_file masc-jsonrpc .json); printf '%%s\\n' \"$f\""
             (quote script))
      in
      if code <> 0 then
        failf "mcp_jsonrpc helper command failed (%d): %s" code stderr;
      match split_nonempty_lines stdout with
      | [ path ] ->
        check bool "temp file exists" true (Sys.file_exists path);
        check bool "json suffix preserved" true (Filename.check_suffix path ".json");
        check bool "template expanded" false
          (contains_substring path "XXXXXX");
        rm_rf path
      | lines ->
        failf "unexpected helper output:\n%s" (String.concat "\n" lines))

let test_keeper_campaign_harness_dry_run () =
  with_temp_dir "keeper-campaign-dry-run" (fun dir ->
      let script =
        Filename.concat (source_root ()) "scripts/harness_keeper_campaign.sh"
      in
      let run_dir = Filename.concat dir "artifacts" in
      let code, _stdout, stderr =
        run_bash ~cwd:(source_root ())
          (Printf.sprintf
             "DRY_RUN=1 START_SERVER=0 RUN_DIR=%s %s"
             (quote run_dir) (quote script))
      in
      if code <> 0 then
        failf "keeper campaign dry run failed (%d): %s" code stderr;
      let summary_path = Filename.concat run_dir "summary.json" in
      let manifest_path = Filename.concat run_dir "manifest.json" in
      let campaign_state_path = Filename.concat run_dir "campaign-state.json" in
      let campaign_events_path = Filename.concat run_dir "campaign-events.jsonl" in
      check bool "summary.json exists" true (Sys.file_exists summary_path);
      check bool "manifest.json exists" true (Sys.file_exists manifest_path);
      check bool "campaign-state.json exists" true (Sys.file_exists campaign_state_path);
      check bool "campaign-events.jsonl exists" true (Sys.file_exists campaign_events_path);
      let summary = read_file summary_path in
      let campaign_state = read_file campaign_state_path in
      check bool "classification present" true
        (contains_substring summary "\"classification\": \"DRY_RUN\"");
      check bool "verdict present" true
        (contains_substring summary "\"verdict\": \"reached\"");
      check bool "campaign phase present" true
        (contains_substring summary "\"campaign_phase\": \"continuity_verified\"");
      check bool "target reached present" true
        (contains_substring summary "\"target_reached\": true");
      check bool "campaign state verdict present" true
        (contains_substring campaign_state "\"verdict\": \"reached\""))

let test_keeper_campaign_cli_replay () =
  with_temp_dir "keeper-campaign-cli" (fun dir ->
      let exe =
        Filename.concat (source_root ()) "_build/default/bin/keeper_campaign_fsm.exe"
      in
      let events_path = Filename.concat dir "events.jsonl" in
      let output_path = Filename.concat dir "state.json" in
      let events =
        String.concat "\n"
          [
            {|{"event":"bootstrap_ok","goal":"cli replay goal"}|};
            {|{"event":"task_bound_observed","task_id":"task-001","current_task_id":"task-001"}|};
            {|{"event":"autoresearch_started","loop_id":"ar-001","target_score":1.0}|};
            {|{"event":"target_reached"}|};
            {|{"event":"pressure_started"}|};
            {|{"event":"handoff_observed","count":1,"generation":2,"trace_id":"trace-2"}|};
            {|{"event":"continuity_observed","goal_matches":true,"current_task_id":"task-001"}|};
            "";
          ]
      in
      let oc = open_out events_path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc events);
      let code, stdout, stderr =
        run_bash ~cwd:(source_root ())
          (Printf.sprintf "%s replay %s %s"
             (quote exe) (quote events_path) (quote output_path))
      in
      if code <> 0 then
        failf "keeper campaign replay failed (%d): %s" code stderr;
      check bool "state output exists" true (Sys.file_exists output_path);
      let output = read_file output_path in
      check bool "stdout verdict present" true
        (contains_substring stdout "\"verdict\": \"reached\"");
      check bool "file verdict present" true
        (contains_substring output "\"verdict\": \"reached\"");
      check bool "continuity phase present" true
        (contains_substring output "\"phase\": \"continuity_verified\""))

let () =
  run "harness_shell_helpers"
    [
      ( "helpers",
        [
          test_case "server bootstrap temp helpers" `Quick
            test_server_bootstrap_temp_helpers;
          test_case "mcp jsonrpc temp helper" `Quick
            test_mcp_jsonrpc_temp_helper;
          test_case "keeper campaign dry run" `Quick
            test_keeper_campaign_harness_dry_run;
          test_case "keeper campaign cli replay" `Quick
            test_keeper_campaign_cli_replay;
        ] );
    ]
