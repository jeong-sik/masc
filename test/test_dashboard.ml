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
          ("trace_id", `String ("trace-" ^ name));
        ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("make_test_meta failed: " ^ err)

let test_keepers_section_empty () =
  let now = Unix.gettimeofday () in
  Lib.Keeper_registry.For_testing.clear ();
  let section = Dashboard.keepers_section now in
  Alcotest.(check string) "title" "Keepers" section.title;
  Alcotest.(check string) "empty_msg" "(no keepers registered)" section.empty_msg;
  Alcotest.(check int) "no content" 0 (List.length section.content)

let test_keepers_section_with_entry () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  Lib.Keeper_registry.For_testing.clear ();
  ignore
    (Lib.Keeper_registry.For_testing.register ~base_path:dir "alpha"
       (make_test_meta "alpha"));
  let now = Unix.gettimeofday () in
  let section = Dashboard.keepers_section now in
  Alcotest.(check string) "title" "Keepers" section.title;
  Alcotest.(check bool) "has content" true (List.length section.content > 0);
  let line = List.hd section.content in
  Alcotest.(check bool) "contains keeper name" true (contains line "alpha");
  Alcotest.(check bool) "contains phase" true (contains line "running");
  Alcotest.(check bool) "contains seq" true (contains line "seq=");
  Lib.Keeper_registry.For_testing.clear ();
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

let test_generate_compact_shows_exact_librarian_facts () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let key = Env_config.KeeperMemoryOs.librarian_env_key in
  let prev = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      (match prev with
       | Some value -> Unix.putenv key value
       | None -> Unix.putenv key "");
      cleanup_dir dir)
    (fun () ->
      Unix.putenv key "false";
      let disabled_output = Dashboard.generate_compact config in
      Alcotest.(check bool)
        "contains LIBRARIAN marker" true (contains disabled_output "LIBRARIAN:");
      Alcotest.(check bool)
        "disabled librarian renders OFF" true
        (contains disabled_output "LIBRARIAN: OFF");
      Alcotest.(check bool)
        "failure counter names process lifetime" true
        (contains disabled_output "LIBRARIAN-FAILURES-SINCE-START:");
      Alcotest.(check bool)
        "retired total label is absent" false
        (contains disabled_output "LIBRARIAN-FAILURES-TOTAL:");
      Unix.putenv key "invalid";
      let invalid_output = Dashboard.generate_compact config in
      Alcotest.(check bool)
        "invalid config is not collapsed into OFF" true
        (contains invalid_output "LIBRARIAN: INVALID");
      Unix.putenv key "true";
      let enabled_output = Dashboard.generate_compact config in
      Alcotest.(check bool)
        "enabled config renders ON" true
        (contains enabled_output "LIBRARIAN: ON"))


let test_keepers_section_with_error_truncated () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  Lib.Keeper_registry.For_testing.clear ();
  ignore
    (Lib.Keeper_registry.For_testing.register ~base_path:dir "echo"
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
  Lib.Keeper_registry.For_testing.clear ();
  cleanup_dir dir

(* ===== Tasks row cap ===== *)

(* In the 72 hours before 2026-11-11 08:40 KST, 80 of the 137 masc_dashboard
   calls came back as a blob preview because the text was 16,388 to 18,719
   bytes against the 16,384 byte inline ceiling. The Tasks section was 8,985
   of 17,424 bytes in a sample, one row per active task. *)
let test_cap_task_rows_without_a_cap () =
  let rows = [ "a"; "b"; "c" ] in
  Alcotest.(check (list string)) "no cap and no pending left out" rows
    (Dashboard.cap_task_rows ~pending_more:0 rows);
  Alcotest.(check (list string)) "pending tasks the pending cap left out are counted"
    [ "a"; "b"; "c"; "   ... +4 more pending" ]
    (Dashboard.cap_task_rows ~pending_more:4 rows);
  Alcotest.(check (list string)) "a cap above the row count changes nothing" rows
    (Dashboard.cap_task_rows ~max_rows:3 ~pending_more:0 rows);
  Alcotest.(check (list string)) "a negative pending count is no pending line" rows
    (Dashboard.cap_task_rows ~pending_more:(-2) rows)

let test_cap_task_rows_counts_what_it_cuts () =
  let rows = [ "a"; "b"; "c"; "d"; "e" ] in
  Alcotest.(check (list string)) "three rows cut, two pending tasks left out earlier"
    [ "a"; "b"; "   ... +5 more not shown" ]
    (Dashboard.cap_task_rows ~max_rows:2 ~pending_more:2 rows);
  Alcotest.(check (list string)) "a zero cap keeps nothing and counts everything"
    [ "   ... +5 more not shown" ]
    (Dashboard.cap_task_rows ~max_rows:0 ~pending_more:0 rows);
  Alcotest.(check (list string)) "a negative cap is a zero cap"
    [ "   ... +5 more not shown" ]
    (Dashboard.cap_task_rows ~max_rows:(-3) ~pending_more:0 rows)

let test_render_within () =
  let rows = List.init 10 (fun index -> Printf.sprintf "row-%05d" index) in
  let render max_rows =
    String.concat "\n"
      ([ "head" ] @ Dashboard.cap_task_rows ?max_rows ~pending_more:0 rows @ [ "tail" ])
  in
  let full = render None in
  Alcotest.(check string) "a text that fits is returned whole" full
    (Dashboard.render_within ~limit:(String.length full) ~row_count:10 render);
  let six = render (Some 6) in
  let fitted = Dashboard.render_within ~limit:(String.length six) ~row_count:10 render in
  Alcotest.(check string) "the most rows that fit are kept" six fitted;
  Alcotest.(check bool) "one more row would not have fit" true
    (String.length (render (Some 7)) > String.length six);
  Alcotest.(check string) "when nothing fits no row is kept" (render (Some 0))
    (Dashboard.render_within ~limit:1 ~row_count:10 render)

let test_generate_max_bytes_keeps_the_other_sections () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  let output = Dashboard.generate ~max_bytes:1 config in
  Alcotest.(check bool) "header stays" true (contains output "MASC Dashboard");
  Alcotest.(check bool) "attention section stays" true (contains output "Attention Required");
  Alcotest.(check bool) "agents section stays" true (contains output "Agents");
  Alcotest.(check bool) "footer stays" true (contains output "Tempo:");
  cleanup_dir dir

let count_of text substr =
  let rec from position found =
    match Str.search_forward (Str.regexp_string substr) text position with
    | at -> from (at + String.length substr) (found + 1)
    | exception Not_found -> found
  in
  from 0 0

(* Four pending tasks with 300 character titles, and a limit 400 bytes under
   the whole text: the Tasks section gives up rows from its tail, says how many,
   and the other sections stay. A limit above the text changes nothing. *)
let test_generate_max_bytes_cuts_the_task_rows () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = test_dir () in
  let config = Workspace_utils.default_config dir in
  setup_workspace config;
  for index = 1 to 4 do
    ignore
      (Lib.Workspace.add_task config
         ~title:(Printf.sprintf "long-task-%d %s" index (String.make 300 'w'))
         ~priority:3 ~description:"d")
  done;
  let full = Dashboard.generate config in
  let limit = String.length full - 400 in
  let cut = Dashboard.generate ~max_bytes:limit config in
  Alcotest.(check bool) "the text fits the limit" true (String.length cut <= limit);
  Alcotest.(check bool) "the Tasks section lists fewer tasks" true
    (count_of cut "(pending)" < count_of full "(pending)");
  Alcotest.(check bool) "it says how many rows it left out" true (contains cut "more not shown");
  Alcotest.(check bool) "the other sections stay" true
    (contains cut "Attention Required" && contains cut "Tempo:");
  let roomy = Dashboard.generate ~max_bytes:(String.length full + 1000) config in
  Alcotest.(check int) "a limit above the text keeps every task row"
    (count_of full "(pending)") (count_of roomy "(pending)");
  Alcotest.(check bool) "and adds no line about rows left out" false
    (contains roomy "more not shown");
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

let task_cap_tests = [
  "cap_task_rows without a cap", `Quick, test_cap_task_rows_without_a_cap;
  "cap_task_rows counts what it cuts", `Quick, test_cap_task_rows_counts_what_it_cuts;
  "render_within keeps the most rows that fit", `Quick, test_render_within;
  "generate max_bytes keeps the other sections", `Quick,
  test_generate_max_bytes_keeps_the_other_sections;
  "generate max_bytes cuts the task rows", `Quick,
  test_generate_max_bytes_cuts_the_task_rows;
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
  "keepers section with error truncated", `Quick, test_keepers_section_with_error_truncated;
  ( "generate compact shows exact librarian facts"
  , `Quick
  , test_generate_compact_shows_exact_librarian_facts );
]

let () =
  Alcotest.run "Dashboard" [
    "Format", format_tests;
    "Timestamp", timestamp_tests;
    "Generate", generate_tests;
    "Sections", section_tests;
    "Task cap", task_cap_tests;
    "Keepers", keepers_tests;
  ]
