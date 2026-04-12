(** Dashboard Tests using Alcotest *)

module Lib = Masc_mcp

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

let setup_room config =
  (* Use Room.init to properly initialize MASC *)
  ignore (Lib.Room.init config ~agent_name:(Some "test-agent"))

(* ===== format_section Tests ===== *)

let test_format_section () =
  let section = Lib.Dashboard.{
    title = "Test Section";
    content = ["Item 1"; "Item 2"; "Item 3"];
    empty_msg = "(empty)";
  } in
  let output = Lib.Dashboard.format_section section in
  Alcotest.(check bool) "has content" true (String.length output > 0);
  Alcotest.(check bool) "contains Item 1" true (contains output "Item 1");
  Alcotest.(check bool) "contains Item 2" true (contains output "Item 2")

let test_format_section_empty () =
  let section = Lib.Dashboard.{
    title = "Empty Section";
    content = [];
    empty_msg = "(nothing here)";
  } in
  let output = Lib.Dashboard.format_section section in
  Alcotest.(check bool) "has empty message" true (contains output "(nothing here)")

(* ===== parse_iso_timestamp Tests ===== *)

let test_parse_timestamp_valid () =
  let valid_ts = "2026-01-09T12:30:45Z" in
  let result = Lib.Dashboard.parse_iso_timestamp valid_ts in
  Alcotest.(check bool) "valid timestamp parses" true (Option.is_some result)

let test_parse_timestamp_invalid () =
  let invalid_ts = "not-a-timestamp" in
  let result = Lib.Dashboard.parse_iso_timestamp invalid_ts in
  Alcotest.(check bool) "invalid timestamp returns None" true (Option.is_none result)

(* ===== generate Tests ===== *)

let test_generate_compact () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Room_utils.default_config dir in
  setup_room config;
  let output = Lib.Dashboard.generate_compact config in
  Alcotest.(check bool) "contains MASC" true (contains output "MASC");
  Alcotest.(check bool) "contains ATTENTION" true (contains output "ATTENTION:");
  Alcotest.(check bool) "contains AGENTS" true (contains output "AGENTS:");
  Alcotest.(check bool) "contains TASKS" true (contains output "TASKS:");
  Alcotest.(check bool) "contains HEALTH" true (contains output "HEALTH:");
  cleanup_dir dir

let test_generate_full () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Room_utils.default_config dir in
  setup_room config;
  let output = Lib.Dashboard.generate config in
  Alcotest.(check bool) "contains MASC Dashboard" true (contains output "MASC Dashboard");
  Alcotest.(check bool) "contains Attention section" true (contains output "Attention Required");
  Alcotest.(check bool) "contains Agents section" true (contains output "Agents");
  Alcotest.(check bool) "contains Swarm Health section" true (contains output "Swarm Health");
  Alcotest.(check bool) "contains Tempo footer" true (contains output "Tempo:");
  cleanup_dir dir

(* ===== Section Tests ===== *)

let test_agents_section_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Room_utils.default_config dir in
  setup_room config;
  let section = Lib.Dashboard.agents_section (Unix.gettimeofday ()) [] in
  Alcotest.(check string) "title" "Agents" section.title;
  Alcotest.(check string) "empty_msg" "(no agents)" section.empty_msg;
  cleanup_dir dir

let test_tasks_section_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Room_utils.default_config dir in
  setup_room config;
  let section = Lib.Dashboard.tasks_section [] in
  Alcotest.(check string) "title" "Tasks" section.title;
  Alcotest.(check string) "empty_msg" "(no tasks)" section.empty_msg;
  cleanup_dir dir

let test_messages_section_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Room_utils.default_config dir in
  setup_room config;
  let section = Lib.Dashboard.messages_section [] in
  Alcotest.(check string) "title" "Recent Messages" section.title;
  Alcotest.(check string) "empty_msg" "(no messages)" section.empty_msg;
  cleanup_dir dir

let test_worktrees_section_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Room_utils.default_config dir in
  setup_room config;
  let section = Lib.Dashboard.worktrees_section config in
  Alcotest.(check string) "title" "Worktrees" section.title;
  Alcotest.(check string) "empty_msg" "(no worktrees)" section.empty_msg;
  cleanup_dir dir

let make_test_meta name =
  match
    Lib.Keeper_types.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String ("trace-" ^ name));
          ( "tool_access",
            Lib.Keeper_types.tool_access_to_json
              (Lib.Keeper_types.Preset
                 { preset = Lib.Keeper_types.Minimal; also_allow = [] }) );
        ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("make_test_meta failed: " ^ err)

let test_keepers_section_empty () =
  let now = Unix.gettimeofday () in
  Lib.Keeper_registry.clear ();
  let section = Lib.Dashboard.keepers_section now in
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
  let section = Lib.Dashboard.keepers_section now in
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
  let config = Room_utils.default_config dir in
  setup_room config;
  let output = Lib.Dashboard.generate config in
  Alcotest.(check bool) "contains Keepers section" true (contains output "Keepers");
  cleanup_dir dir

let test_generate_compact_contains_keepers () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Room_utils.default_config dir in
  setup_room config;
  let output = Lib.Dashboard.generate_compact config in
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
  let section = Lib.Dashboard.keepers_section now in
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
  Lib.Keeper_registry.record_error ~base_path:dir "echo" long_err;
  let now = Unix.gettimeofday () in
  let section = Lib.Dashboard.keepers_section now in
  let line = List.hd section.content in
  Alcotest.(check bool) "contains err= marker" true (contains line "err=");
  Alcotest.(check bool) "contains truncation ellipsis" true (contains line "...");
  (* Error body should be bounded by max_message_length (default 35),
     so the total line cannot contain the full 130-char error verbatim. *)
  Alcotest.(check bool) "long error body is not verbatim"
    false (contains line "ellipsis");
  Lib.Keeper_registry.clear ();
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
  "worktrees section empty", `Quick, test_worktrees_section_empty;
]

let keepers_tests = [
  "keepers section empty", `Quick, test_keepers_section_empty;
  "keepers section with entry", `Quick, test_keepers_section_with_entry;
  "generate full contains keepers", `Quick, test_generate_full_contains_keepers;
  "generate compact contains keepers", `Quick, test_generate_compact_contains_keepers;
  "keepers section dead phase", `Quick, test_keepers_section_dead_phase;
  "keepers section with error truncated", `Quick, test_keepers_section_with_error_truncated;
]

let () =
  Alcotest.run "Dashboard" [
    "Format", format_tests;
    "Timestamp", timestamp_tests;
    "Generate", generate_tests;
    "Sections", section_tests;
    "Keepers", keepers_tests;
  ]
