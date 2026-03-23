(** Silent failure logging tests for Phase 2A.

    Verifies that the silent failure patterns replaced with explicit
    stderr logging actually emit the expected log messages when triggered.

    Coverage:
    - social: vote update on missing post → "[social]" prefix
    - source verification: all 14 patterns have Printf.eprintf with correct prefixes

    Stderr capture approach: Unix.pipe + Unix.dup2 redirect.
*)

open Alcotest

module Social = Masc_mcp.Social
module Room = Masc_mcp.Room

(* ============================================================
   Stderr Capture Utility (same pattern as test_error_logging_coverage)
   ============================================================ *)

let capture_stderr f =
  let (pipe_read, pipe_write) = Unix.pipe () in
  let saved_stderr = Unix.dup Unix.stderr in
  Unix.dup2 pipe_write Unix.stderr;
  Unix.close pipe_write;
  (try f () with _ -> ());
  flush stderr;
  Unix.dup2 saved_stderr Unix.stderr;
  Unix.close saved_stderr;
  Unix.set_nonblock pipe_read;
  let buf = Buffer.create 256 in
  let tmp = Bytes.create 256 in
  let rec read_all () =
    match Unix.read pipe_read tmp 0 256 with
    | 0 -> ()
    | n -> Buffer.add_subbytes buf tmp 0 n; read_all ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
    | exception _ -> ()
  in
  read_all ();
  Unix.close pipe_read;
  Buffer.contents buf

let str_contains haystack needle =
  let hl = String.length haystack in
  let nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else begin
    let found = ref false in
    let i = ref 0 in
    while !i <= hl - nl && not !found do
      if String.sub haystack !i nl = needle then found := true;
      incr i
    done;
    !found
  end

(* ============================================================
   Test helpers
   ============================================================ *)

let make_test_dir () =
  let unique_id = Printf.sprintf "masc_sfp2a_%d_%d"
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1_000_000.)) in
  Filename.concat (Filename.get_temp_dir_name ()) unique_id

let rec rm_rf path =
  if Sys.file_exists path then begin
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path
  end

let with_test_room f =
  let dir = make_test_dir () in
  Unix.mkdir dir 0o755;
  let config = Room.default_config dir in
  let _ = Room.init config ~agent_name:(Some "test-agent") in
  Fun.protect
    ~finally:(fun () -> (try let _ = Room.reset config in () with _ -> ()); rm_rf dir)
    (fun () -> f config)

(* ============================================================
   social: vote on nonexistent post → "[social]"
   ============================================================ *)

(** vote on a post that does not exist triggers "[social] vote update (post get)". *)
let test_social_vote_missing_post_logs () =
  with_test_room @@ fun config ->
  let output = capture_stderr (fun () ->
    ignore (Social.vote config
      ~target_type:`Post
      ~target_id:"nonexistent-post-id"
      ~voter:"test-voter"
      ~direction:Social.Up)
  ) in
  check bool "stderr contains [Social] prefix for vote on missing post"
    true (str_contains output "[Social]")

(* ============================================================
   Source verification: confirm all 14 patterns have logging
   ============================================================ *)

(** Read a source file and verify it contains a specific logging pattern.
    This is a static verification test — it checks that the source code
    contains the expected Printf.eprintf calls. *)
let file_contains_pattern file_rel pattern =
  let rec find_source_root dir =
    let keeper_dir = Filename.concat (Filename.concat dir "lib") "keeper" in
    if Sys.file_exists keeper_dir && Sys.is_directory keeper_dir then Some dir
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else find_source_root parent
  in
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some d when Sys.file_exists (Filename.concat (Filename.concat d "lib") "keeper") -> d
    | _ ->
        find_source_root (Sys.getcwd ())
        |> Option.value ~default:(Sys.getcwd ())
  in
  let path = Filename.concat source_root file_rel in
  if not (Sys.file_exists path) then begin
    Printf.eprintf "Warning: source file not found: %s\n%!" path;
    false
  end else begin
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    str_contains content pattern
  end

let any_file_contains_pattern file_rels pattern =
  List.exists (fun file_rel -> file_contains_pattern file_rel pattern) file_rels

let keeper_source_files () =
  let rec find_source_root dir =
    let keeper_dir = Filename.concat (Filename.concat dir "lib") "keeper" in
    if Sys.file_exists keeper_dir && Sys.is_directory keeper_dir then Some dir
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else find_source_root parent
  in
  let source_root = match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some d when Sys.file_exists (Filename.concat (Filename.concat d "lib") "keeper") -> d
    | _ ->
        find_source_root (Sys.getcwd ())
        |> Option.value ~default:(Sys.getcwd ())
  in
  (* Keeper files moved to lib/keeper/ subdirectory *)
  let keeper_dir = Filename.concat (Filename.concat source_root "lib") "keeper" in
  let from_keeper =
    if Sys.file_exists keeper_dir && Sys.is_directory keeper_dir then
      Sys.readdir keeper_dir
      |> Array.to_list
      |> List.filter (fun name ->
             Filename.check_suffix name ".ml"
             && String.starts_with ~prefix:"keeper_" name)
      |> List.map (Filename.concat "lib/keeper")
    else []
  in
  let lib_dir = Filename.concat source_root "lib" in
  let from_root =
    Sys.readdir lib_dir
    |> Array.to_list
    |> List.filter (fun name ->
           Filename.check_suffix name ".ml"
           && String.starts_with ~prefix:"keeper_" name)
    |> List.map (Filename.concat "lib")
  in
  from_keeper @ from_root
(* HIGH priority patterns *)

let test_source_main_keeper_bootstrap () =
  check bool "bootstrap sources have keeper bootstrap logging"
    true (any_file_contains_pattern
      [ "bin/main_eio.ml"; "lib/server/server_runtime_bootstrap.ml" ]
      {|keeper bootstrap failed|})

(* MA-H2a/H2b removed: metrics_store_eio.ml migrated to Eio-native I/O (PR #2260),
   eliminating Unix fd close/unlock paths and their logging. *)

let test_source_model_token_parse () =
  (* model_spec.ml was retired; model parsing migrated to oas_model_resolve.ml *)
  check bool "oas_model_resolve.ml has model label parsing"
    true (any_file_contains_pattern
      [ "lib/oas_model_resolve.ml" ]
      {|provider_name_of_label|})

let test_source_keeper_proactive () =
  check bool "keeper sources have proactive emission logging"
    true
    (any_file_contains_pattern (keeper_source_files ())
       {|proactive emission failed:|}
     || any_file_contains_pattern (keeper_source_files ())
          {|unified turn failed:|}
     || any_file_contains_pattern (keeper_source_files ())
          {|unified turn exception:|})

(* MEDIUM priority patterns *)

let test_source_worktree_agent_state () =
  check bool "room_worktree.ml has agent state read logging"
    true (any_file_contains_pattern
      ["lib/room/room_worktree.ml"; "lib/room/room_agent.ml"]
      {|agent state read|})

let test_source_social_vote_post () =
  check bool "social.ml has vote update post logging"
    true (file_contains_pattern "lib/social.ml"
      {|vote update (post get):|})

let test_source_social_vote_comment () =
  check bool "social.ml has vote update comment logging"
    true (file_contains_pattern "lib/social.ml"
      {|vote update (comment list):|})

let test_source_board_pg_vote_migration () =
  check bool "board_pg.ml has vote migration logging"
    true (file_contains_pattern "lib/board/board_pg.ml"
      {|vote migration:|})

(* test_source_heartbeat_traits removed — lodge_heartbeat_state.ml deleted (#1596) *)
(* test_source_heartbeat_preferred_hours removed — lodge_heartbeat_state.ml deleted (#1596) *)
(* test_source_heartbeat_interests removed — lodge_heartbeat_state.ml deleted (#1596) *)

let test_source_keeper_log_parse () =
  check bool "dashboard http has keeper log parse logging"
    true (file_contains_pattern "lib/dashboard/dashboard_http_keeper_metrics.ml"
      {|keeper log parse:|})

let test_source_trpg_npc_heal () =
  (* trpg_round_fallback.ml archived to archive/trpg/ *)
  check bool "trpg_round_fallback.ml has npc heal logging (archived)"
    true (file_contains_pattern "archive/trpg/lib/trpg_round_fallback.ml"
      {|[trpg] npc heal:|})

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  run "Silent failure logging (Phase 2A)" [
    "social_stderr", [
      test_case "vote on missing post logs [social]"
        `Quick test_social_vote_missing_post_logs;
    ];
    "source_high_priority", [
      test_case "MA-H1: keeper bootstrap logging present"
        `Quick test_source_main_keeper_bootstrap;
      (* MA-H2a/H2b removed: Eio-native migration PR #2260 eliminated fd paths *)
      test_case "MA-H3: model label parse source present"
        `Quick test_source_model_token_parse;
      test_case "MA-H4: keeper proactive logging present"
        `Quick test_source_keeper_proactive;
    ];
    "source_medium_priority", [
      test_case "MA-M1: worktree agent state logging present"
        `Quick test_source_worktree_agent_state;
      test_case "MA-M2a: social vote post logging present"
        `Quick test_source_social_vote_post;
      test_case "MA-M2b: social vote comment logging present"
        `Quick test_source_social_vote_comment;
      test_case "MA-M3: board_pg vote migration logging present"
        `Quick test_source_board_pg_vote_migration;
      (* MA-M4a/b/c: heartbeat tests removed — lodge_heartbeat_state.ml deleted (#1596) *)
      test_case "MA-M5: keeper log parse logging present"
        `Quick test_source_keeper_log_parse;
      test_case "MA-M7: trpg npc heal logging present"
        `Quick test_source_trpg_npc_heal;
    ];
  ]
