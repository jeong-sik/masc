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
  write_file (Filename.concat dir ".gitignore") ".masc/\n";
  write_file (Filename.concat dir "sample.ml") "let value = 1\n";
  run_ok ~cwd:dir "git add .gitignore sample.ml && git -c core.hooksPath=/dev/null commit -q -m base"

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
    ]
