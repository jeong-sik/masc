(** Keeper Tool Exposure Tests

    Verifies that keeper_allowed_tool_names returns the full tool set
    unconditionally, with voice tools available by default,
    and write_done producing empty list. *)

open Alcotest
open Masc_mcp

(* ============================================================
   Test Helpers
   ============================================================ *)

let make_meta ?(name = "test-keeper") ?(soul_profile = "")
    ?(policy_voice_enabled = false) ?(tool_allowlist = []) () : Keeper_types.keeper_meta =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String name);
        ("trace_id", `String "test-trace-exposure");
        ("soul_profile", `String soul_profile);
        ("policy_voice_enabled", `Bool policy_voice_enabled);
        ("tool_allowlist", `List (List.map (fun s -> `String s) tool_allowlist));
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)

let has_tool name tools = List.mem name tools
let has_any_prefix prefix tools =
  List.exists (fun n -> String.length n >= String.length prefix
    && String.sub n 0 (String.length prefix) = prefix) tools

(* ============================================================
   1. write_done isolation
   ============================================================ *)

let test_write_done_blocks_all_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names ~write_done:true meta in
  check int "write_done=true returns empty list" 0 (List.length tools)

let test_write_done_false_has_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names ~write_done:false meta in
  check bool "write_done=false returns nonempty" true (List.length tools > 0)

(* ============================================================
   2. Default profile — all keepers get all tools (mode removed)
   ============================================================ *)

let test_default_has_base_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has tools" true (List.length tools > 0);
  check bool "has keeper_time_now" true (has_tool "keeper_time_now" tools);
  check bool "has keeper_context_status" true (has_tool "keeper_context_status" tools)

let test_default_has_voice () =
  let meta = make_meta ~policy_voice_enabled:false () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "voice tools available by default" true
    (has_tool "keeper_voice_speak" tools)

let test_default_has_governance_tools () =
  let meta = make_meta ~tool_allowlist:["masc_governance_status"; "masc_case_brief_submit"] () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has governance status" true
    (has_tool "masc_governance_status" tools);
  check bool "has case brief submit" true
    (has_tool "masc_case_brief_submit" tools)

let test_default_has_research_tools () =
  (* Autoresearch tools need allowlist since deny-by-default *)
  let meta = make_meta ~soul_profile:"default"
    ~tool_allowlist:["masc_autoresearch_cycle"; "masc_autoresearch_status";
                     "masc_autoresearch_inject"; "masc_autoresearch_stop"] () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has autoresearch" true (has_any_prefix "masc_autoresearch_" tools)

(* ============================================================
   3. Voice tools are always available
   ============================================================ *)

let test_voice_enabled_adds_voice_tools () =
  let meta = make_meta ~policy_voice_enabled:true () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_voice_speak" true (has_tool "keeper_voice_speak" tools);
  check bool "has keeper_voice_agent" true (has_tool "keeper_voice_agent" tools);
  check bool "has keeper_voice_sessions" true (has_tool "keeper_voice_sessions" tools)

let test_voice_disabled_no_voice_tools () =
  let meta = make_meta ~policy_voice_enabled:false () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "voice_speak still available" true (has_tool "keeper_voice_speak" tools);
  check bool "voice_agent still available" true (has_tool "keeper_voice_agent" tools)

(* ============================================================
   4. All keepers get shell tools (mode removed)
   ============================================================ *)

let test_all_keepers_have_shell_readonly () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_shell_readonly" true
    (has_tool "keeper_shell_readonly" tools)

(* ============================================================
   5. All keepers get coding tools (mode removed)
   ============================================================ *)

let test_all_keepers_have_coding_tools () =
  let coding_names = Tool_code_write.tool_names in
  let meta = make_meta ~tool_allowlist:(coding_names @ ["masc_worktree_create"; "masc_code_search"]) () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let has_any_coding = List.exists (fun n -> has_tool n tools) coding_names in
  check bool "coding tools present" true has_any_coding;
  check bool "has worktree create" true
    (has_tool "masc_worktree_create" tools);
  check bool "has code search" true
    (has_tool "masc_code_search" tools)

(* ============================================================
   6. All keepers get autoresearch tools (mode removed)
   ============================================================ *)

let test_all_keepers_have_autoresearch () =
  let meta = make_meta ~soul_profile:"teaching"
    ~tool_allowlist:["masc_autoresearch_cycle"; "masc_autoresearch_status";
                     "masc_autoresearch_inject"; "masc_autoresearch_stop"] () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has autoresearch" true (has_any_prefix "masc_autoresearch_" tools)

(* ============================================================
   7. All modes produce same tool set (mode removed)
   ============================================================ *)

let test_all_modes_same_tool_count () =
  let heuristic = make_meta () in
  let learned = make_meta ~soul_profile:"research" () in
  let h_tools = Keeper_exec_tools.keeper_allowed_tool_names heuristic in
  let l_tools = Keeper_exec_tools.keeper_allowed_tool_names learned in
  check int "same tool count across modes"
    (List.length h_tools) (List.length l_tools)

let test_any_mode_has_board_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_board_get" true (has_tool "keeper_board_get" tools);
  check bool "has keeper_board_post" true (has_tool "keeper_board_post" tools)

let test_any_mode_has_read_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  (* keeper_read removed: dead alias with no schema, keeper_fs_read is the actual tool *)
  check bool "has keeper_fs_read" true (has_tool "keeper_fs_read" tools);
  check bool "has keeper_library_search" true (has_tool "keeper_library_search" tools)

let test_any_mode_has_coordination_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_tasks_list" true
    (has_tool "keeper_tasks_list" tools);
  check bool "has keeper_task_claim" true
    (has_tool "keeper_task_claim" tools);
  check bool "has keeper_broadcast" true
    (has_tool "keeper_broadcast" tools)

let test_any_mode_has_governance_tools () =
  let meta = make_meta ~tool_allowlist:["masc_governance_status"; "masc_petition_submit"] () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has governance status" true
    (has_tool "masc_governance_status" tools);
  check bool "has petition submit" true
    (has_tool "masc_petition_submit" tools)

let test_sufficient_tool_count () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "tool count from shards" true (List.length tools >= 20)

(* ============================================================
   8. Combined profiles
   ============================================================ *)

let test_research_learned_voice_combined () =
  let meta = make_meta ~soul_profile:"research"
    ~policy_voice_enabled:true
    ~tool_allowlist:["masc_autoresearch_cycle"; "masc_autoresearch_status"] () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has voice" true (has_tool "keeper_voice_speak" tools);
  check bool "has shell readonly" true (has_tool "keeper_shell_readonly" tools);
  check bool "has autoresearch" true (has_any_prefix "masc_autoresearch_" tools);
  check bool "has board" true (has_tool "keeper_board_get" tools);
  check bool "has read" true (has_tool "keeper_fs_read" tools)

(* ============================================================
   9. Tool deduplication
   ============================================================ *)

let test_no_duplicate_tools () =
  let meta = make_meta ~soul_profile:"research"
    ~policy_voice_enabled:true () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let unique = List.sort_uniq String.compare tools in
  check int "no duplicates" (List.length unique) (List.length tools)

(* ============================================================
   10. Path resolution security (resolve_keeper_target_path)
   ============================================================ *)

let make_path_test_dir () =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "keeper_path_test_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (* Create .git dir so find_git_root stops here instead of finding CI repo root *)
  let git_dir = Filename.concat dir ".git" in
  (try Unix.mkdir git_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let sub = Filename.concat dir "lib" in
  (try Unix.mkdir sub 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let sub2 = Filename.concat dir "src" in
  (try Unix.mkdir sub2 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let cleanup_path_test_dir dir =
  let rec rm path =
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
      Unix.rmdir path
    end else
      Sys.remove path
  in
  (try rm dir with _ -> ())

let test_path_relative_within_root () =
  let dir = make_path_test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_path_test_dir dir) (fun () ->
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Room.default_config dir in
    let result = Keeper_alerting_path.resolve_keeper_target_path
      ~config ~allowed_paths:[] ~raw_path:"lib/foo.ml" in
    check bool "relative path within root ok" true (Result.is_ok result))

let test_path_absolute_outside_root () =
  let dir = make_path_test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_path_test_dir dir) (fun () ->
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Room.default_config dir in
    let result = Keeper_alerting_path.resolve_keeper_target_path
      ~config ~allowed_paths:[] ~raw_path:"/etc/passwd" in
    check bool "absolute outside root rejected" true (Result.is_error result);
    let err = Result.get_error result in
    check bool "error mentions outside" true
      (String.length err > 0
       && try let _ = Str.search_forward
         (Str.regexp_string "path_outside_project_root") err 0 in true
       with Not_found -> false))

let test_path_traversal_attack () =
  (* Use a deep nested dir so ../../ reliably escapes root on any CI *)
  let base = make_path_test_dir () in
  let deep = Filename.concat (Filename.concat base "a") "b" in
  (try Unix.mkdir (Filename.concat base "a") 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir deep 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect ~finally:(fun () -> cleanup_path_test_dir base) (fun () ->
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Room.default_config deep in
    (* ../../../../etc/passwd should escape any reasonable root *)
    let result = Keeper_alerting_path.resolve_keeper_target_path
      ~config ~allowed_paths:[] ~raw_path:"../../../../etc/passwd" in
    check bool "traversal attack rejected" true (Result.is_error result))

let test_path_allowed_paths_filter () =
  let dir = make_path_test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_path_test_dir dir) (fun () ->
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Room.default_config dir in
    (* lib is allowed, src is not *)
    let ok_result = Keeper_alerting_path.resolve_keeper_target_path
      ~config ~allowed_paths:["lib"] ~raw_path:"lib/foo.ml" in
    check bool "lib path allowed" true (Result.is_ok ok_result);
    let err_result = Keeper_alerting_path.resolve_keeper_target_path
      ~config ~allowed_paths:["lib"] ~raw_path:"src/bar.ml" in
    check bool "src path rejected" true (Result.is_error err_result);
    let err = Result.get_error err_result in
    check bool "error mentions allowed_paths" true
      (try let _ = Str.search_forward
        (Str.regexp_string "path_not_in_allowed_paths") err 0 in true
       with Not_found -> false))

let test_path_empty_rejected () =
  let dir = make_path_test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_path_test_dir dir) (fun () ->
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Room.default_config dir in
    let result = Keeper_alerting_path.resolve_keeper_target_path
      ~config ~allowed_paths:[] ~raw_path:"" in
    check bool "empty path rejected" true (Result.is_error result))

let test_path_whitespace_only_rejected () =
  let dir = make_path_test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_path_test_dir dir) (fun () ->
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Room.default_config dir in
    let result = Keeper_alerting_path.resolve_keeper_target_path
      ~config ~allowed_paths:[] ~raw_path:"   " in
    check bool "whitespace path rejected" true (Result.is_error result))

let test_path_empty_allowed_permits_all_within_root () =
  let dir = make_path_test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_path_test_dir dir) (fun () ->
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Room.default_config dir in
    (* Empty allowed_paths = permit all within root *)
    let r1 = Keeper_alerting_path.resolve_keeper_target_path
      ~config ~allowed_paths:[] ~raw_path:"lib/a.ml" in
    let r2 = Keeper_alerting_path.resolve_keeper_target_path
      ~config ~allowed_paths:[] ~raw_path:"src/b.ml" in
    check bool "lib ok with empty allowed" true (Result.is_ok r1);
    check bool "src ok with empty allowed" true (Result.is_ok r2))

(* ============================================================
   Runner
   ============================================================ *)

let () =
  run "Keeper_tool_exposure" [
    ("write_done", [
      test_case "blocks all tools" `Quick test_write_done_blocks_all_tools;
      test_case "false has tools" `Quick test_write_done_false_has_tools;
    ]);
    ("default_profile", [
      test_case "has base tools" `Quick test_default_has_base_tools;
      test_case "has voice tools" `Quick test_default_has_voice;
      test_case "has governance tools" `Quick test_default_has_governance_tools;
      test_case "has research tools" `Quick test_default_has_research_tools;
    ]);
    ("voice_profile", [
      test_case "enabled adds voice" `Quick test_voice_enabled_adds_voice_tools;
      test_case "disabled no voice" `Quick test_voice_disabled_no_voice_tools;
    ]);
    ("shell_tools", [
      test_case "all keepers have shell readonly" `Quick test_all_keepers_have_shell_readonly;
    ]);
    ("coding_tools", [
      test_case "all keepers have coding tools" `Quick test_all_keepers_have_coding_tools;
    ]);
    ("autoresearch_tools", [
      test_case "all keepers have autoresearch" `Quick test_all_keepers_have_autoresearch;
    ]);
    ("mode_free_access", [
      test_case "all modes same tool count" `Quick test_all_modes_same_tool_count;
      test_case "has board tools" `Quick test_any_mode_has_board_tools;
      test_case "has read tools" `Quick test_any_mode_has_read_tools;
      test_case "has coordination tools" `Quick test_any_mode_has_coordination_tools;
      test_case "has governance tools" `Quick test_any_mode_has_governance_tools;
      test_case "sufficient tool count" `Quick test_sufficient_tool_count;
    ]);
    ("combined_profiles", [
      test_case "research+learned+voice+readonly" `Quick test_research_learned_voice_combined;
    ]);
    ("deduplication", [
      test_case "no duplicate tools" `Quick test_no_duplicate_tools;
    ]);
    ("path_resolution", [
      test_case "relative within root" `Quick test_path_relative_within_root;
      test_case "absolute outside root" `Quick test_path_absolute_outside_root;
      test_case "traversal attack" `Quick test_path_traversal_attack;
      test_case "allowed_paths filter" `Quick test_path_allowed_paths_filter;
      test_case "empty path rejected" `Quick test_path_empty_rejected;
      test_case "whitespace only rejected" `Quick test_path_whitespace_only_rejected;
      test_case "empty allowed permits all" `Quick test_path_empty_allowed_permits_all_within_root;
    ]);
  ]
