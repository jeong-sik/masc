(** Dashboard Tests using Alcotest *)

module Lib = Masc

(** Helper to check if str contains substring *)
let contains str substr =
  try
    ignore (Str.search_forward (Str.regexp_string substr) str 0);
    true
  with Not_found -> false

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_test" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
      Unix.rmdir path
    end else
      Sys.remove path
  in
  if Sys.file_exists dir then rm dir

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

let append_file path content =
  let oc =
    open_out_gen [ Open_creat; Open_text; Open_append ] 0o644 path
  in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

let first_jsonl_file_under dir =
  let months =
    Sys.readdir dir
    |> Array.to_list
    |> List.sort String.compare
  in
  let rec find_month = function
    | [] -> None
    | month :: rest ->
      let month_dir = Filename.concat dir month in
      if Sys.is_directory month_dir then
        let days =
          Sys.readdir month_dir
          |> Array.to_list
          |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
          |> List.sort String.compare
        in
        (match days with
         | day :: _ -> Some (Filename.concat month_dir day)
         | [] -> find_month rest)
      else find_month rest
  in
  find_month months

let with_config_dir config_root f =
  let prev = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match prev with
       | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_root;
      Config_dir_resolver.reset ();
      f ())

let setup_workspace config =
  (* Use Workspace.init to properly initialize MASC *)
  ignore (Lib.Workspace.init config ~agent_name:(Some "test-agent"))

(* ===== format_section Tests ===== *)

let test_format_section () =
  let section = Dashboard.{
    title = "Test Section";
    content = ["Item 1"; "Item 2"; "Item 3"];
    empty_msg = "(empty)";
  } in
  let output = Dashboard.format_section section in
  Alcotest.(check bool) "has content" true (String.length output > 0);
  Alcotest.(check bool) "contains Item 1" true (contains output "Item 1");
  Alcotest.(check bool) "contains Item 2" true (contains output "Item 2")

let test_format_section_empty () =
  let section = Dashboard.{
    title = "Empty Section";
    content = [];
    empty_msg = "(nothing here)";
  } in
  let output = Dashboard.format_section section in
  Alcotest.(check bool) "has empty message" true (contains output "(nothing here)")

(* ===== parse_iso_timestamp Tests ===== *)

let test_parse_timestamp_valid () =
  let valid_ts = "2026-01-09T12:30:45Z" in
  let result = Dashboard.parse_iso_timestamp valid_ts in
  Alcotest.(check bool) "valid timestamp parses" true (Option.is_some result)

let test_parse_timestamp_invalid () =
  let invalid_ts = "not-a-timestamp" in
  let result = Dashboard.parse_iso_timestamp invalid_ts in
  Alcotest.(check bool) "invalid timestamp returns None" true (Option.is_none result)

(* ===== generate Tests ===== *)

let test_generate_compact () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let output = Dashboard.generate_compact config in
  Alcotest.(check bool) "contains MASC" true (contains output "MASC");
  Alcotest.(check bool) "contains ATTENTION" true (contains output "ATTENTION:");
  Alcotest.(check bool) "contains AGENTS" true (contains output "AGENTS:");
  Alcotest.(check bool) "contains TASKS" true (contains output "TASKS:");
  cleanup_dir dir

let test_generate_full () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let output = Dashboard.generate config in
  Alcotest.(check bool) "contains MASC Dashboard" true (contains output "MASC Dashboard");
  Alcotest.(check bool) "contains Attention section" true (contains output "Attention Required");
  Alcotest.(check bool) "contains Agents section" true (contains output "Agents");
  Alcotest.(check bool) "contains Tempo footer" true (contains output "Tempo:");
  cleanup_dir dir

(* ===== Section Tests ===== *)

let test_agents_section_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let section = Dashboard.agents_section (Unix.gettimeofday ()) [] in
  Alcotest.(check string) "title" "Agents" section.title;
  Alcotest.(check string) "empty_msg" "(no agents)" section.empty_msg;
  cleanup_dir dir

let test_tasks_section_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let section = Dashboard.tasks_section [] in
  Alcotest.(check string) "title" "Tasks" section.title;
  Alcotest.(check string) "empty_msg" "(no tasks)" section.empty_msg;
  cleanup_dir dir

let test_messages_section_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let section = Dashboard.messages_section [] in
  Alcotest.(check string) "title" "Recent Messages" section.title;
  Alcotest.(check string) "empty_msg" "(no messages)" section.empty_msg;
  cleanup_dir dir

let make_test_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String ("trace-" ^ name));
          ("tool_access", Json_util.json_string_list []);
        ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("make_test_meta failed: " ^ err)

let test_keepers_section_empty () =
  let now = Unix.gettimeofday () in
  Lib.Keeper_registry.clear ();
  let section = Dashboard.keepers_section now in
  Alcotest.(check string) "title" "Keepers" section.title;
  Alcotest.(check string) "empty_msg" "(no keepers registered)" section.empty_msg;
  Alcotest.(check int) "no content" 0 (List.length section.content)

let test_keepers_section_with_entry () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  Lib.Keeper_registry.clear ();
  ignore
    (Lib.Keeper_registry.register ~base_path:dir "alpha"
       (make_test_meta "alpha"));
  let now = Unix.gettimeofday () in
  let section = Dashboard.keepers_section now in
  Alcotest.(check string) "title" "Keepers" section.title;
  Alcotest.(check bool) "has content" true (List.length section.content > 0);
  let line = List.hd section.content in
  Alcotest.(check bool) "contains keeper name" true (contains line "alpha");
  Alcotest.(check bool) "contains phase" true (contains line "running");
  Alcotest.(check bool) "contains seq" true (contains line "seq=");
  Lib.Keeper_registry.clear ();
  cleanup_dir dir

let test_generate_full_contains_keepers () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let output = Dashboard.generate config in
  Alcotest.(check bool) "contains Keepers section" true (contains output "Keepers");
  cleanup_dir dir

let test_generate_compact_contains_keepers () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let output = Dashboard.generate_compact config in
  Alcotest.(check bool) "contains KEEPERS line" true (contains output "KEEPERS:");
  cleanup_dir dir

let test_keepers_section_dead_phase () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  Lib.Keeper_registry.clear ();
  ignore
    (Lib.Keeper_registry.register ~base_path:dir "delta"
       (make_test_meta "delta"));
  let now_mark = Unix.gettimeofday () in
  Lib.Keeper_registry.mark_dead ~base_path:dir "delta" ~at:now_mark;
  let now = Unix.gettimeofday () in
  let section = Dashboard.keepers_section now in
  Alcotest.(check int) "one entry" 1 (List.length section.content);
  let line = List.hd section.content in
  Alcotest.(check bool) "contains delta" true (contains line "delta");
  Alcotest.(check bool) "contains dead phase" true (contains line "dead");
  Alcotest.(check bool) "contains since= marker" true (contains line "since=");
  Lib.Keeper_registry.clear ();
  cleanup_dir dir

let test_keepers_section_with_error_truncated () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  Lib.Keeper_registry.clear ();
  ignore
    (Lib.Keeper_registry.register ~base_path:dir "echo"
       (make_test_meta "echo"));
  let long_err =
    "this is a long error message that should exceed the default display length of 35 chars and therefore be truncated with an ellipsis"
  in
  Lib.Keeper_registry_error_recording.record ~base_path:dir "echo" long_err;
  let now = Unix.gettimeofday () in
  let section = Dashboard.keepers_section now in
  let line = List.hd section.content in
  Alcotest.(check bool) "contains err= marker" true (contains line "err=");
  Alcotest.(check bool) "contains truncation ellipsis" true (contains line "...");
  (* Error body should be bounded by max_message_length (default 35),
     so the total line cannot contain the full 130-char error verbatim. *)
  Alcotest.(check bool) "long error body is not verbatim"
    false (contains line "ellipsis");
  Lib.Keeper_registry.clear ();
  cleanup_dir dir

let test_agent_relations_graphql_errors_are_visible () =
  let json =
    Lib.Dashboard_agent_relations.For_testing.json_from_query_results
      ~agent_name:"alice"
      ~generated_at_iso:"2026-07-05T04:24:00Z"
      ~collaborators_result:(Error "HTTP 503")
      ~agent_result:(Error "GraphQL data is null")
  in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "collaborators unknown"
    false
    (json |> member "collaborators_known" |> to_bool);
  Alcotest.(check bool)
    "interests unknown"
    false
    (json |> member "interests_known" |> to_bool);
  Alcotest.(check bool)
    "relations unknown"
    false
    (json |> member "relations_known" |> to_bool);
  Alcotest.(check int)
    "two read errors"
    2
    (json |> member "read_errors" |> to_list |> List.length);
  Alcotest.(check int)
    "compat collaborators array remains empty"
    0
    (json |> member "collaborators" |> to_list |> List.length)

let test_agent_relations_success_has_known_empty_sections () =
  let collaborators_result =
    Ok
      (`Assoc
        [ ( "agentCollaborationNetworkByName"
          , `List
              [ `Assoc
                  [ "name", `String "critic"
                  ; "collaborations", `Int 3
                  ; "lastCollab", `Null
                  ]
              ] )
        ])
  in
  let agent_result =
    Ok
      (`Assoc
        [ ( "agent"
          , `Assoc
              [ "interests", `List [ `String "code-review" ]
              ; "relations", `Assoc [ "edges", `List [] ]
              ] )
        ])
  in
  let json =
    Lib.Dashboard_agent_relations.For_testing.json_from_query_results
      ~agent_name:"alice"
      ~generated_at_iso:"2026-07-05T04:24:00Z"
      ~collaborators_result
      ~agent_result
  in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "collaborators known"
    true
    (json |> member "collaborators_known" |> to_bool);
  Alcotest.(check bool)
    "interests known"
    true
    (json |> member "interests_known" |> to_bool);
  Alcotest.(check bool)
    "relations known"
    true
    (json |> member "relations_known" |> to_bool);
  Alcotest.(check int)
    "no read errors"
    0
    (json |> member "read_errors" |> to_list |> List.length);
  Alcotest.(check int)
    "one collaborator"
    1
    (json |> member "collaborators" |> to_list |> List.length)

let test_keeper_feature_proof_surfaces_keeper_name_read_error () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let keeper_dir = Lib.Keeper_types_profile.keeper_dir config in
  if Sys.file_exists keeper_dir then cleanup_dir keeper_dir;
  write_file keeper_dir "not a keeper directory";
  let json = Lib.Dashboard_keeper_feature_proof.json ~config () in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "keeper names unknown"
    false
    (json |> member "keeper_names_known" |> to_bool);
  Alcotest.(check int)
    "top-level read error"
    1
    (json |> member "read_errors" |> to_list |> List.length);
  Alcotest.(check bool)
    "summary keeper names unknown"
    false
    (json |> member "summary" |> member "keeper_names_known" |> to_bool);
  Alcotest.(check int)
    "summary read error"
    1
    (json |> member "summary" |> member "read_errors" |> to_list |> List.length);
  cleanup_dir dir

let test_keeper_feature_proof_surfaces_decision_log_parse_error () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  Lib.Keeper_registry.clear ();
  let keeper_name = "feature-proof-parse-error" in
  let meta = make_test_meta keeper_name in
  (match Lib.Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error err -> Alcotest.fail ("write_meta failed: " ^ err));
  let decision_path =
    Lib.Keeper_types_support.keeper_decision_log_path config keeper_name
  in
  Fs_compat.mkdir_p (Filename.dirname decision_path);
  write_file decision_path "{not-json\n";
  let json = Lib.Dashboard_keeper_feature_proof.json ~config () in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "top-level decision-log read error"
    true
    (json |> member "read_error_count" |> to_int >= 1);
  Alcotest.(check bool)
    "summary decision-log read error"
    true
    (json |> member "summary" |> member "read_error_count" |> to_int >= 1);
  let read_errors = json |> member "read_errors" |> to_list in
  Alcotest.(check bool)
    "top-level read error source"
    true
    (read_errors
     |> List.exists (fun error ->
       error |> member "source" |> to_string
       = "dashboard_keeper_decision_log_jsonl"));
  let features = json |> member "features" |> to_list in
  let persistent =
    features
    |> List.find (fun feature ->
      feature |> member "id" |> to_string = "persistent_24h_turn_exchange")
  in
  Alcotest.(check int)
    "persistent feature read error"
    1
    (persistent |> member "read_errors" |> to_list |> List.length);
  let per_keeper =
    persistent |> member "keeper_evidence" |> member "per_keeper" |> to_list
  in
  let evidence =
    per_keeper
    |> List.find (fun row -> row |> member "keeper" |> to_string = keeper_name)
  in
  Alcotest.(check int)
    "per-keeper read error count"
    1
    (evidence |> member "read_error_count" |> to_int);
  cleanup_dir dir

let test_keeper_dashboard_surfaces_keeper_name_read_error () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let keeper_dir = Lib.Keeper_types_profile.keeper_dir config in
  if Sys.file_exists keeper_dir then cleanup_dir keeper_dir;
  write_file keeper_dir "not a keeper directory";
  let json = Lib.Dashboard_http_keeper.keepers_dashboard_json config in
  let trust_json = Lib.Dashboard_http_keeper.execution_trust_dashboard_json config in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "dashboard keeper names unknown"
    false
    (json |> member "keeper_names_known" |> to_bool);
  Alcotest.(check bool)
    "dashboard keeper count unknown"
    false
    (json |> member "keeper_count_known" |> to_bool);
  Alcotest.(check int)
    "dashboard read error"
    1
    (json |> member "read_errors" |> to_list |> List.length);
  Alcotest.(check bool)
    "execution trust keeper names unknown"
    false
    (trust_json |> member "keeper_names_known" |> to_bool);
  Alcotest.(check bool)
    "execution trust keeper count unknown"
    false
    (trust_json |> member "keeper_count_known" |> to_bool);
  Alcotest.(check bool)
    "execution trust read errors non-empty"
    true
    ((trust_json |> member "read_errors" |> to_list) <> []);
  cleanup_dir dir

let test_execution_trust_surfaces_coverage_gap_parse_error () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let masc_root = Lib.Workspace.masc_root_dir config in
  Lib.Telemetry_coverage_gap.record
    ~masc_root
    ~source:"execution_receipt"
    ~producer:"keeper_agent_run.execution_receipt"
    ~durable_store:(Filename.concat masc_root "keepers")
    ~dashboard_surface:"/api/v1/dashboard/execution-trust"
    ~stale_reason:"append_failed"
    ~error:"disk full"
    ();
  let coverage_gap_dir =
    Filename.concat masc_root "telemetry-coverage-gaps"
  in
  let gap_path =
    match first_jsonl_file_under coverage_gap_dir with
    | Some path -> path
    | None -> Alcotest.fail "expected coverage-gap JSONL file"
  in
  append_file gap_path "{not-json\n";
  let json = Lib.Dashboard_http_keeper.execution_trust_dashboard_json config in
  let open Yojson.Safe.Util in
  Alcotest.(check int)
    "valid coverage gap remains visible"
    1
    (json |> member "coverage_gap_count" |> to_int);
  Alcotest.(check int)
    "coverage gap read error count"
    1
    (json |> member "coverage_gap_read_error_count" |> to_int);
  let read_error =
    match json |> member "coverage_gap_read_errors" |> to_list with
    | [ error ] -> error
    | errors ->
      Alcotest.failf "expected one coverage-gap read error, got %d"
        (List.length errors)
  in
  Alcotest.(check string)
    "read error source"
    "telemetry_coverage_gap_jsonl"
    (read_error |> member "source" |> to_string);
  Alcotest.(check string)
    "read error kind"
    "json_error"
    (read_error |> member "kind" |> to_string);
  Alcotest.(check int)
    "read error recent index"
    1
    (read_error |> member "recent_index" |> to_int);
  Alcotest.(check bool)
    "root read errors include coverage-gap parse error"
    true
    (json |> member "read_errors" |> to_list |> List.exists (fun error ->
       match error |> member "source" with
       | `String source -> String.equal source "telemetry_coverage_gap_jsonl"
       | _ -> false));
  cleanup_dir dir

let test_keeper_dashboard_surfaces_metrics_parse_error () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  Lib.Keeper_registry.clear ();
  let keeper_name = "metrics-parse-error" in
  let meta = make_test_meta keeper_name in
  (match Lib.Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error err -> Alcotest.fail ("write_meta failed: " ^ err));
  ignore (Lib.Keeper_registry.register ~base_path:dir keeper_name meta);
  let metrics_path =
    Lib.Keeper_types_support.keeper_metrics_path config keeper_name
  in
  Fs_compat.mkdir_p (Filename.dirname metrics_path);
  let valid_metrics =
    `Assoc
      [ ("ts_unix", `Float (Unix.gettimeofday ()))
      ; ("context_ratio", `Float 0.25)
      ; ("context_tokens", `Int 128)
      ; ("context_max", `Int 512)
      ; ("message_count", `Int 3)
      ; ("channel", `String "reactive")
      ]
    |> Yojson.Safe.to_string
  in
  write_file metrics_path ("{not-json\n" ^ valid_metrics ^ "\n");
  let json = Lib.Dashboard_http_keeper.keepers_dashboard_json config in
  let open Yojson.Safe.Util in
  let rows = json |> member "keepers" |> to_list in
  let row =
    match
      List.find_opt
        (fun row ->
          match row |> member "name" with
          | `String value -> String.equal value keeper_name
          | _ -> false)
        rows
    with
    | Some row -> row
    | None -> Alcotest.fail "expected keeper dashboard row"
  in
  Alcotest.(check int)
    "row metrics parse error count"
    1
    (row |> member "metrics_parse_error_count" |> to_int);
  Alcotest.(check bool)
    "row metrics parse errors are visible"
    true
    ((row |> member "metrics_parse_errors" |> to_list) <> []);
  let has_root_metrics_error =
    json
    |> member "read_errors"
    |> to_list
    |> List.exists (fun error ->
      match error |> member "source" with
      | `String source -> String.equal source "keeper_metrics_jsonl_parse"
      | _ -> false)
  in
  Alcotest.(check bool)
    "root read errors include metrics parse"
    true
    has_root_metrics_error;
  cleanup_dir dir

let test_dashboard_execution_workspace_status_surfaces_state_read_error () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  write_file (Lib.Workspace.state_path config) "{not-json\n";
  let json = Dashboard_execution.workspace_status_json config in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "workspace state status"
    "default_from_read_error"
    (json |> member "workspace_state_status" |> to_string);
  Alcotest.(check int)
    "workspace state read error count"
    1
    (json |> member "workspace_state_read_error_count" |> to_int);
  (match json |> member "workspace_state_read_errors" |> to_list with
   | _ :: _ -> ()
   | [] -> Alcotest.fail "expected workspace_state_read_errors to explain the read failure");
  cleanup_dir dir

(* ===== Test Suite ===== *)

let format_tests = [
  "format_section with content", `Quick, test_format_section;
  "format_section empty", `Quick, test_format_section_empty;
]

let timestamp_tests = [
  "parse valid timestamp", `Quick, test_parse_timestamp_valid;
  "parse invalid timestamp", `Quick, test_parse_timestamp_invalid;
]

let generate_tests = [
  "generate compact", `Quick, test_generate_compact;
  "generate full", `Quick, test_generate_full;
]

let section_tests = [
  "agents section empty", `Quick, test_agents_section_empty;
  "tasks section empty", `Quick, test_tasks_section_empty;
  "messages section empty", `Quick, test_messages_section_empty;
]

let keepers_tests = [
  "keepers section empty", `Quick, test_keepers_section_empty;
  "keepers section with entry", `Quick, test_keepers_section_with_entry;
  "generate full contains keepers", `Quick, test_generate_full_contains_keepers;
  "generate compact contains keepers", `Quick, test_generate_compact_contains_keepers;
  "keepers section dead phase", `Quick, test_keepers_section_dead_phase;
  "keepers section with error truncated", `Quick, test_keepers_section_with_error_truncated;
]

let agent_relations_tests = [
  "graphql errors are visible", `Quick, test_agent_relations_graphql_errors_are_visible;
  "success has known empty sections", `Quick, test_agent_relations_success_has_known_empty_sections;
]

let keeper_feature_proof_tests = [
  "keeper name read errors are visible", `Quick, test_keeper_feature_proof_surfaces_keeper_name_read_error;
  "keeper decision-log parse errors are visible", `Quick, test_keeper_feature_proof_surfaces_decision_log_parse_error;
  "keeper dashboard read errors are visible", `Quick, test_keeper_dashboard_surfaces_keeper_name_read_error;
  "execution trust coverage-gap parse errors are visible", `Quick, test_execution_trust_surfaces_coverage_gap_parse_error;
  "keeper dashboard metrics parse errors are visible", `Quick, test_keeper_dashboard_surfaces_metrics_parse_error;
]

let execution_tests = [
  "workspace status state read errors are visible", `Quick,
    test_dashboard_execution_workspace_status_surfaces_state_read_error;
]

let () =
  Alcotest.run "Dashboard" [
    "Format", format_tests;
    "Timestamp", timestamp_tests;
    "Generate", generate_tests;
    "Sections", section_tests;
    "Keepers", keepers_tests;
    "Agent relations", agent_relations_tests;
    "Keeper feature proof", keeper_feature_proof_tests;
    "Execution", execution_tests;
  ]
