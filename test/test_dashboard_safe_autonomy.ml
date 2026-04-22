open Alcotest
open Masc_mcp

module Coord = Masc_mcp.Coord
module KT = Masc_mcp.Keeper_types

let test_counter = ref 0

let tmpdir prefix =
  incr test_counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%d"
         prefix (Unix.getpid ()) !test_counter
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let with_env name value_opt f =
  let previous = Sys.getenv_opt name in
  (match value_opt with
   | Some value -> Unix.putenv name value
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv name value
      | None -> Unix.putenv name "")
    f

let with_safe_autonomy_store f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = tmpdir "safe_autonomy" in
  let config = Coord.default_config base_dir in
  ignore (Coord.init config ~agent_name:None);
  f config

let write_file path contents =
  match Fs_compat.save_file_atomic path contents with
  | Ok () -> ()
  | Error err -> fail ("save_file_atomic failed: " ^ err)

let make_meta ?(name = "bench-analyst") ?(trace_id = "trace-safe-autonomy") () =
  match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String "bench-analyst-agent");
          ("trace_id", `String trace_id);
          ("cascade_name", `String Keeper_config.default_cascade_name);
          ("last_model_used", `String "openai:gpt-5.4");
          ("goal", `String "Keep autonomy safe and observable");
          ("short_goal", `String "Handle code work with approval and sandbox guardrails");
          ("mid_goal", `String "Keep the keeper queue healthy");
          ("long_goal", `String "Reach product-grade safe autonomy");
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let task_id value =
  match Keeper_id.Task_id.of_string value with
  | Ok id -> id
  | Error err -> fail ("Task_id.of_string failed: " ^ err)

let persist_keeper config =
  let meta =
    {
      (make_meta ()) with
      active_goal_ids = [ "goal-short"; "goal-mid" ];
      current_task_id = Some (task_id "task-safe-autonomy");
      runtime =
        {
          (make_meta ()).runtime with
          usage =
            {
              (make_meta ()).runtime.usage with
              total_turns = 3;
              last_turn_ts = Unix.gettimeofday ();
              last_model_used = "openai:gpt-5.4";
            };
          trace_history = [ "trace-safe-autonomy-prev" ];
        };
    }
  in
  match KT.write_meta ~force:true config meta with
  | Ok () ->
      let sandbox_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
      Fs_compat.mkdir_p sandbox_root;
      let repo_path =
        Keeper_repo_readiness.clone_path ~config ~meta ~repo_name:"masc-mcp"
      in
      Fs_compat.mkdir_p repo_path;
      meta
  | Error err -> fail ("write_meta failed: " ^ err)

let write_manifest path =
  write_file path
    (Yojson.Safe.pretty_to_string
       (`Assoc
         [
           ("version", `Int 1);
           ("generated_at", `String "2026-04-22T00:00:00Z");
           ("recommendations",
            `List
              [
                `Assoc
                  [
                    ("keeper_profile", `String "bench-analyst");
                    ("model_label", `String "openai:gpt-5.4");
                    ("composite_score", `Float 100.0);
                    ("task_pass_rate", `Float 1.0);
                    ("stability_score", `Float 1.0);
                    ("cases_total", `Int 3);
                    ("cases_passed", `Int 3);
                  ];
              ]);
         ]))

let require_assoc key json = Yojson.Safe.Util.(json |> member key)

let test_json_emits_scorecard_and_artifacts () =
  with_safe_autonomy_store @@ fun config ->
  ignore (persist_keeper config);
  let manifest_path = Filename.concat (tmpdir "safe_autonomy_manifest") "manifest.json" in
  Fs_compat.mkdir_p (Filename.dirname manifest_path);
  write_manifest manifest_path;
  with_env "MASC_KEEPER_BENCH_CANARY_ENABLED" (Some "true") (fun () ->
    with_env "MASC_KEEPER_BENCH_CANARY_PATH" (Some manifest_path) (fun () ->
      let json = Dashboard_safe_autonomy.json ~config () in
      let summary = require_assoc "summary" json in
      let artifacts = require_assoc "artifacts" json in
      let per_keeper = Yojson.Safe.Util.(json |> member "per_keeper" |> to_list) in
      let domains = Yojson.Safe.Util.(json |> member "domains" |> to_list) in
      check int "keeper_count" 1
        Yojson.Safe.Util.(summary |> member "keeper_count" |> to_int);
      check bool "artifacts latest exists" true
        (Fs_compat.file_exists
           Yojson.Safe.Util.(artifacts |> member "latest_path" |> to_string));
      check bool "artifacts history exists" true
        (Fs_compat.file_exists
           Yojson.Safe.Util.(artifacts |> member "history_path" |> to_string));
      check int "per_keeper count" 1 (List.length per_keeper);
      check bool "domain includes tool correctness" true
        (List.exists
           (fun item ->
             Yojson.Safe.Util.(item |> member "id" |> to_string = "tool_correctness"))
           domains)))

let test_history_dedupes_identical_payloads () =
  with_safe_autonomy_store @@ fun config ->
  ignore (persist_keeper config);
  let manifest_path = Filename.concat (tmpdir "safe_autonomy_manifest") "manifest.json" in
  Fs_compat.mkdir_p (Filename.dirname manifest_path);
  write_manifest manifest_path;
  with_env "MASC_KEEPER_BENCH_CANARY_ENABLED" (Some "true") (fun () ->
    with_env "MASC_KEEPER_BENCH_CANARY_PATH" (Some manifest_path) (fun () ->
      let first = Dashboard_safe_autonomy.json ~config () in
      let second = Dashboard_safe_autonomy.json ~config () in
      let latest_path =
        Yojson.Safe.Util.(first |> member "artifacts" |> member "latest_path" |> to_string)
      in
      let history_path =
        Yojson.Safe.Util.(second |> member "artifacts" |> member "history_path" |> to_string)
      in
      let latest_json =
        match Safe_ops.read_json_file_safe latest_path with
        | Ok json -> json
        | Error err -> fail ("read_json_file_safe failed: " ^ err)
      in
      let history_lines =
        match Safe_ops.read_file_safe history_path with
        | Ok contents ->
            contents
            |> String.split_on_char '\n'
            |> List.filter (fun line -> String.trim line <> "")
        | Error err -> fail ("read_file_safe failed: " ^ err)
      in
      check int "history lines stay deduped" 1 (List.length history_lines);
      check bool "latest file is valid json" true
        (match latest_json with `Assoc _ -> true | _ -> false)))

let () =
  run "dashboard_safe_autonomy"
    [
      ( "dashboard_safe_autonomy",
        [
          test_case "json emits scorecard and artifacts" `Quick
            test_json_emits_scorecard_and_artifacts;
          test_case "artifact history dedupes identical payloads" `Quick
            test_history_dedupes_identical_payloads;
        ] );
    ]
