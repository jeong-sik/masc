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
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect
    ~finally:(fun () ->
      Process_eio.reset_for_testing ();
      Eio_guard.disable ();
      Fs_compat.clear_fs ())
    f

let quote = Filename.quote

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

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
  write_file (Filename.concat dir "other.ml") "let other = 1\n";
  run_ok ~cwd:dir "git add .gitignore sample.ml other.ml && git -c core.hooksPath=/dev/null commit -q -m base"

let test_capture_only_on_change () =
  with_temp_dir "worktree-live-context" (fun dir ->
      init_repo dir;
      Wlc.clear_status_cache_for_tests ();
      check (option string) "clean repo produces no block" None
        (Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a");
      check (option string) "clean repo stays quiet after state write" None
        (Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a");
      write_file (Filename.concat dir "sample.ml") "let value = 2\n";
      Wlc.clear_status_cache_for_tests ();
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
      Wlc.clear_status_cache_for_tests ();
      ignore (Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a");
      write_file (Filename.concat dir "other.ml") "let other = 2\n";
      Wlc.clear_status_cache_for_tests ();
      let second =
        Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a"
      in
      check bool "new change produces new block" true (Option.is_some second);
      let block = Option.value ~default:"" second in
      check bool "block mentions second file" true
        (try
           ignore
             (Str.search_forward
                (Str.regexp_string "other.ml")
                block 0);
           true
         with Not_found -> false))

let test_capture_change_block_in_eio_runtime () =
  with_temp_dir "worktree-live-context" (fun dir ->
      init_repo dir;
      write_file (Filename.concat dir "sample.ml") "let value = 2\n";
      Wlc.clear_status_cache_for_tests ();
      with_eio_runtime (fun () ->
        let first = Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a" in
        check bool "changed repo produces block in eio" true (Option.is_some first);
        check (option string) "same change not repeated in eio" None
          (Wlc.capture_change_block ~base_path:dir ~actor_key:"keeper-a")))

let test_current_status_lines_uses_short_cache_and_no_optional_locks () =
  Wlc.clear_status_cache_for_tests ();
  let calls = ref [] in
  Wlc.set_git_capture_hook_for_tests (fun ~workdir:_ args ->
      calls := args :: !calls;
      Some [ " M sample.ml" ]);
  Fun.protect
    ~finally:(fun () ->
      Wlc.clear_git_capture_hook_for_tests ();
      Wlc.clear_status_cache_for_tests ())
    (fun () ->
      let first = Wlc.current_status_lines ~repo_root:"/tmp/repo" in
      let second = Wlc.current_status_lines ~repo_root:"/tmp/repo" in
      check (list string) "first status" [ "M sample.ml" ] first;
      check (list string) "second status" [ "M sample.ml" ] second;
      check int "git status called once" 1 (List.length !calls);
      check (list string) "git status args"
        [ "--no-optional-locks"; "status"; "--porcelain"; "--untracked-files=no" ]
        (List.hd !calls))

let test_current_status_lines_caches_clean_status () =
  Wlc.clear_status_cache_for_tests ();
  let calls = ref 0 in
  Wlc.set_git_capture_hook_for_tests (fun ~workdir:_ _args ->
      incr calls;
      Some []);
  Fun.protect
    ~finally:(fun () ->
      Wlc.clear_git_capture_hook_for_tests ();
      Wlc.clear_status_cache_for_tests ())
    (fun () ->
      check (list string) "first clean status" []
        (Wlc.current_status_lines ~repo_root:"/tmp/repo");
      check (list string) "second clean status" []
        (Wlc.current_status_lines ~repo_root:"/tmp/repo");
      check int "clean status is cached" 1 !calls)

let test_git_status_timeout_defaults_to_30_seconds () =
  with_env "MASC_WORKTREE_GIT_STATUS_TIMEOUT_SEC" "" (fun () ->
      check (float 0.01) "default git status timeout" 30.0
        (Wlc.git_status_timeout_sec ()))

let test_git_status_timeout_honors_env_override () =
  with_env "MASC_WORKTREE_GIT_STATUS_TIMEOUT_SEC" "12.5" (fun () ->
      check (float 0.01) "env override" 12.5
        (Wlc.git_status_timeout_sec ()))

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
          test_case "status cache uses no optional locks" `Quick
            test_current_status_lines_uses_short_cache_and_no_optional_locks;
          test_case "status cache keeps clean status" `Quick
            test_current_status_lines_caches_clean_status;
          test_case "git status timeout defaults to 30s" `Quick
            test_git_status_timeout_defaults_to_30_seconds;
          test_case "git status timeout honors env override" `Quick
            test_git_status_timeout_honors_env_override;
        ] );
    ]
