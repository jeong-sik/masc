open Alcotest

module Wlc = Masc_mcp.Worktree_live_context

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

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

let with_eio_runtime f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Fun.protect
    ~finally:(fun () ->
      Eio_guard.disable ();
      Fs_compat.clear_fs ())
    f

let quote = Filename.quote

let run_ok ~cwd cmd =
  let wrapped = Printf.sprintf "cd %s && %s > /dev/null 2>&1" (quote cwd) cmd in
  let code = Sys.command wrapped in
  if code <> 0 then failf "command failed (%d): %s" code cmd

let init_repo dir =
  run_ok ~cwd:dir "git init -q";
  run_ok ~cwd:dir "git config user.email test@example.com";
  run_ok ~cwd:dir "git config user.name tester";
  write_file (Filename.concat dir "sample.ml") "let value = 1\n";
  run_ok ~cwd:dir "git add sample.ml && git -c core.hooksPath=/dev/null commit -q -m base"

let test_capture_only_on_change () =
  with_temp_dir "worktree-live-context" (fun dir ->
      init_repo dir;
      check (option string) "clean repo produces no block" None
        (Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a");
      check (option string) "clean repo stays quiet after state write" None
        (Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a");
      write_file (Filename.concat dir "sample.ml") "let value = 2\n";
      let first =
        Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a"
      in
      check bool "changed repo produces block" true (Option.is_some first);
      let block = Option.value ~default:"" first in
      check bool "block mentions changed file" true
        (try
           ignore
             (Str.search_forward
                (Str.regexp_string "sample.ml")
                block 0);
           true
         with Not_found -> false);
      check (option string) "same change not repeated" None
        (Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a"))

let test_capture_distinguishes_new_changes () =
  with_temp_dir "worktree-live-context" (fun dir ->
      init_repo dir;
      write_file (Filename.concat dir "sample.ml") "let value = 2\n";
      ignore (Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a");
      write_file (Filename.concat dir "other.md") "new notes\n";
      let second =
        Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a"
      in
      check bool "new change produces new block" true (Option.is_some second);
      let block = Option.value ~default:"" second in
      check bool "block mentions second file" true
        (try
           ignore
             (Str.search_forward
                (Str.regexp_string "other.md")
                block 0);
           true
         with Not_found -> false))

let test_capture_change_block_in_eio_runtime () =
  with_temp_dir "worktree-live-context" (fun dir ->
      init_repo dir;
      write_file (Filename.concat dir "sample.ml") "let value = 2\n";
      with_eio_runtime (fun () ->
        let first = Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a" in
        check bool "changed repo produces block in eio" true (Option.is_some first);
        check (option string) "same change not repeated in eio" None
          (Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a")))

(** Regression: pre-filter rejects paths that operators leave dirty in
    the repo root (data/*.jsonl, memory/*.md, tmp_edit/, pr_*.json, etc).
    Without this filter, every keeper's evidence turn recorded the full
    operator-local working tree as its own "modifications", producing
    34+ cross-keeper collision warnings per turn. *)
let test_current_status_lines_filters_operator_noise () =
  with_temp_dir "status-exclude" (fun dir ->
    init_repo dir;
    (* Create untracked operator junk in the excluded roots. *)
    Unix.mkdir (Filename.concat dir "data") 0o755;
    write_file (Filename.concat dir "data/run.jsonl") "row\n";
    Unix.mkdir (Filename.concat dir "memory") 0o755;
    write_file (Filename.concat dir "memory/note.md") "hi\n";
    Unix.mkdir (Filename.concat dir "tmp_edit") 0o755;
    write_file (Filename.concat dir "tmp_edit/scratch.txt") "x\n";
    write_file (Filename.concat dir "pr_430.json") "{}\n";
    write_file (Filename.concat dir "cr_latest.txt") "..\n";
    write_file (Filename.concat dir "comments_430.txt") "..\n";
    (* Plus one legitimate keeper-modified tracked file. *)
    write_file (Filename.concat dir "sample.ml") "let value = 2\n";
    let lines = Wlc.current_status_lines ~repo_root:dir in
    check int "only the real keeper change surfaces" 1 (List.length lines);
    let only = List.hd lines in
    check bool "returned line mentions sample.ml" true
      (try
         ignore
           (Str.search_forward (Str.regexp_string "sample.ml") only 0);
         true
       with Not_found -> false))

(** Keeper-created source files (untracked at first) MUST still surface
    in evidence — that's the whole point of tracking new files. *)
let test_current_status_lines_keeps_keeper_new_files () =
  with_temp_dir "status-new" (fun dir ->
    init_repo dir;
    write_file (Filename.concat dir "new_module.ml") "let x = 1\n";
    let lines = Wlc.current_status_lines ~repo_root:dir in
    check int "untracked keeper file surfaces" 1 (List.length lines))

let () =
  run "Worktree_live_context"
    [
      ( "capture_change_block",
        [
          test_case "only on change" `Quick test_capture_only_on_change;
          test_case "distinguishes new changes" `Quick
            test_capture_distinguishes_new_changes;
          test_case "works in Eio runtime" `Quick
            test_capture_change_block_in_eio_runtime;
        ] );
      ( "current_status_lines",
        [
          test_case "filters operator-noise paths (data/, memory/, pr_*.json, etc.)"
            `Quick test_current_status_lines_filters_operator_noise;
          test_case "keeps keeper-created new files"
            `Quick test_current_status_lines_keeps_keeper_new_files;
        ] );
    ]
