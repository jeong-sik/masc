(** Integration tests for Repo_git — exercises real git commands. *)

open Repo_manager_types

let with_temp_dir f =
  let dir = Filename.temp_file "repo_git_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path then
          if Sys.is_directory path then begin
            Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
            Unix.rmdir path
          end else
            Sys.remove path
      in
      rm_rf dir)
    (fun () -> f dir)

let run_cmd ~cwd argv =
  let prev = Sys.getcwd () in
  Sys.chdir cwd;
  Fun.protect
    ~finally:(fun () -> Sys.chdir prev)
    (fun () ->
       let pid =
         Unix.create_process_env
           (List.hd argv)
           (Array.of_list argv)
           (Unix.environment ())
           Unix.stdin Unix.stdout Unix.stderr
       in
       match Unix.waitpid [] pid with
       | _, Unix.WEXITED 0 -> Ok ()
       | _, Unix.WEXITED code -> Error (Printf.sprintf "exit %d" code)
       | _, Unix.WSIGNALED s -> Error (Printf.sprintf "signal %d" s)
       | _, Unix.WSTOPPED s -> Error (Printf.sprintf "stopped %d" s))

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let init_local_repo path =
  Unix.mkdir path 0o755;
  let () =
    match run_cmd ~cwd:path ["git"; "init"; "-b"; "main"] with
    | Ok () -> ()
    | Error e -> failwith ("git init failed: " ^ e)
  in
  let () =
    match
      run_cmd ~cwd:path ["git"; "config"; "user.email"; "test@example.com"]
    with
    | Ok () -> ()
    | Error e -> failwith e
  in
  let () =
    match
      run_cmd ~cwd:path ["git"; "config"; "user.name"; "Test User"]
    with
    | Ok () -> ()
    | Error e -> failwith e
  in
  let () =
    match
      run_cmd ~cwd:path ["git"; "commit"; "--allow-empty"; "-m"; "initial"]
    with
    | Ok () -> ()
    | Error e -> failwith ("git commit failed: " ^ e)
  in
  let () =
    match run_cmd ~cwd:path ["git"; "branch"; "develop"] with
    | Ok () -> ()
    | Error e -> failwith ("git branch develop failed: " ^ e)
  in
  ()

let sample_repo ~url local_path =
  {
    id = "test-repo";
    name = "test-repo";
    url;
    local_path;
    aliases = [];
    default_branch = "main";
    keepers = [];
    status = Active;
    auto_sync = false;
    sync_interval = 0;
    created_at = Int64.zero;
    updated_at = Int64.zero;
  }

let test_clone_ok () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let dest = Filename.concat tmp "dest" in
      let repo = sample_repo ~url:source dest in
      match Repo_git.clone ~repository:repo with
      | Ok () ->
          Alcotest.(check bool) "dest exists" true (Sys.file_exists dest);
          Alcotest.(check bool) "dest/.git exists" true
            (Sys.file_exists (Filename.concat dest ".git"))
      | Error e -> Alcotest.fail ("clone failed: " ^ e))

let test_clone_bad_url () =
  with_temp_dir (fun tmp ->
      let dest = Filename.concat tmp "dest" in
      let repo = sample_repo ~url:"/nonexistent/path/to/repo" dest in
      match Repo_git.clone ~repository:repo with
      | Ok () -> Alcotest.fail "expected clone to fail"
      | Error _ -> ())

let test_get_branches () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let dest = Filename.concat tmp "dest" in
      let repo = sample_repo ~url:source dest in
      match Repo_git.clone ~repository:repo with
      | Error e -> Alcotest.fail ("clone failed: " ^ e)
      | Ok () -> (
          match Repo_git.get_branches ~repository:repo with
          | Error e -> Alcotest.fail ("get_branches failed: " ^ e)
          | Ok branches ->
              Alcotest.(check bool) "has main" true (List.mem "main" branches)))

let test_get_origin_url () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      (match
         run_cmd
           ~cwd:source
           [ "git"; "remote"; "add"; "origin"; "https://example.test/owner/repo.git" ]
       with
       | Ok () -> ()
       | Error e -> Alcotest.fail ("git remote add failed: " ^ e));
      match Repo_git.get_origin_url ~local_path:source () with
      | Ok url ->
          Alcotest.(check string)
            "origin URL"
            "https://example.test/owner/repo.git"
            url
      | Error e ->
        Alcotest.fail
          ("get_origin_url failed: " ^ Repo_git.origin_lookup_error_to_string e))

let test_get_origin_url_reports_missing_without_text_matching () =
  with_temp_dir (fun tmp ->
    let source = Filename.concat tmp "source" in
    init_local_repo source;
    match Repo_git.get_origin_url ~local_path:source () with
    | Error Repo_git.Origin_missing -> ()
    | Error error ->
      Alcotest.failf
        "unexpected missing-origin outcome: %s"
        (Repo_git.origin_lookup_error_to_string error)
    | Ok url -> Alcotest.failf "missing origin returned URL %s" url)

let test_get_origin_url_times_out_on_stalled_config () =
  with_temp_dir (fun tmp ->
      let fake_bin = Filename.concat tmp "bin" in
      Unix.mkdir fake_bin 0o755;
      let fake_git = Filename.concat fake_bin "git" in
      write_file fake_git "#!/bin/sh\nsleep 30\n";
      Unix.chmod fake_git 0o755;
      let old_path = Sys.getenv "PATH" in
      Fun.protect
        ~finally:(fun () -> Unix.putenv "PATH" old_path)
        (fun () ->
          Unix.putenv "PATH" (fake_bin ^ ":" ^ old_path);
          let started_at = Unix.gettimeofday () in
          match Repo_git.get_origin_url ~local_path:tmp () with
          | Ok url -> Alcotest.failf "expected timeout, got origin %s" url
          | Error (Repo_git.Origin_lookup_timed_out error) ->
              let elapsed = Unix.gettimeofday () -. started_at in
              Alcotest.(check bool)
                "reports timeout"
                true
                (String_util.contains_substring error "timeout after 5s");
              Alcotest.(check bool)
                "returns within a bounded interval"
                true
                (elapsed >= 4.0 && elapsed < 10.0)
          | Error error ->
            Alcotest.failf
              "expected typed timeout, got %s"
              (Repo_git.origin_lookup_error_to_string error)))

let test_get_origin_url_uses_read_only_git_env () =
  with_temp_dir (fun tmp ->
    let source = Filename.concat tmp "source" in
    init_local_repo source;
    (match
       run_cmd
         ~cwd:source
         [ "git"; "remote"; "add"; "origin"; "https://example.test/owner/repo.git" ]
     with
     | Ok () -> ()
     | Error e -> Alcotest.fail ("git remote add failed: " ^ e));
    let captured = ref [] in
    Fun.protect
      ~finally:(fun () -> Exec_tap.disable ())
      (fun () ->
         Exec_tap.enable ~writer:(fun line -> captured := line :: !captured);
         match Repo_git.get_origin_url ~local_path:source () with
         | Error e ->
           Alcotest.fail
             ("origin failed: " ^ Repo_git.origin_lookup_error_to_string e)
         | Ok _ ->
           let joined = String.concat "\n" (List.rev !captured) in
           Alcotest.(check bool)
             "sets GIT_OPTIONAL_LOCKS env key"
             true
             (String_util.contains_substring joined "\"GIT_OPTIONAL_LOCKS\"")))

let test_fetch () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let dest = Filename.concat tmp "dest" in
      let repo = sample_repo ~url:source dest in
      match Repo_git.clone ~repository:repo with
      | Error e -> Alcotest.fail ("clone failed: " ^ e)
      | Ok () -> (
          match Repo_git.fetch ~repository:repo with
          | Error e -> Alcotest.fail ("fetch failed: " ^ e)
          | Ok remotes ->
              Alcotest.(check bool) "has origin/main" true
                (List.mem "origin/main" remotes)))

let test_get_recent_commits () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let dest = Filename.concat tmp "dest" in
      let repo = sample_repo ~url:source dest in
      match Repo_git.clone ~repository:repo with
      | Error e -> Alcotest.fail ("clone failed: " ^ e)
      | Ok () -> (
          match Repo_git.get_recent_commits ~repository:repo ~branch:"main" ~limit:5 with
          | Error e -> Alcotest.fail ("get_recent_commits failed: " ^ e)
          | Ok commits ->
              Alcotest.(check bool) "at least 1 commit" true
                (List.length commits >= 1);
              Alcotest.(check bool) "contains initial" true
                (List.exists (fun s -> String_util.contains_substring s "initial") commits)))

let test_status_summary_counts_porcelain_rows () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      (match run_cmd ~cwd:source ["git"; "checkout"; "-b"; "status-work"] with
      | Ok () -> ()
      | Error e -> Alcotest.fail ("git checkout status-work failed: " ^ e));
      let tracked = Filename.concat source "tracked.txt" in
      write_file tracked "committed\n";
      (match run_cmd ~cwd:source ["git"; "add"; "tracked.txt"] with
      | Ok () -> ()
      | Error e -> Alcotest.fail ("git add failed: " ^ e));
      (match run_cmd ~cwd:source ["git"; "commit"; "-m"; "tracked"] with
      | Ok () -> ()
      | Error e -> Alcotest.fail ("git commit tracked failed: " ^ e));
      let repo = sample_repo ~url:source source in
      (match Repo_git.status_summary ~repository:repo () with
      | Error e -> Alcotest.fail ("clean status failed: " ^ e)
      | Ok summary ->
          Alcotest.(check int) "clean changed" 0 summary.changed_files);
      write_file tracked "modified\n";
      write_file (Filename.concat source "untracked.txt") "new\n";
      (match Repo_git.status_summary ~repository:repo () with
      | Error e -> Alcotest.fail ("dirty status failed: " ^ e)
      | Ok summary ->
          Alcotest.(check int) "dirty changed" 2 summary.changed_files;
          Alcotest.(check int) "dirty unstaged" 1 summary.unstaged_files;
          Alcotest.(check int) "dirty untracked" 1 summary.untracked_files;
          Alcotest.(check int) "dirty staged" 0 summary.staged_files);
      (match run_cmd ~cwd:source ["git"; "add"; "tracked.txt"] with
      | Ok () -> ()
      | Error e -> Alcotest.fail ("git add modified failed: " ^ e));
      match Repo_git.status_summary ~repository:repo () with
      | Error e -> Alcotest.fail ("staged status failed: " ^ e)
      | Ok summary ->
          Alcotest.(check int) "staged changed" 2 summary.changed_files;
          Alcotest.(check int) "staged tracked" 1 summary.staged_files;
          Alcotest.(check int) "staged unstaged" 0 summary.unstaged_files;
          Alcotest.(check int) "staged untracked" 1 summary.untracked_files)

let test_status_summary_uses_read_only_git_conventions () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let repo = sample_repo ~url:source source in
      let captured = ref [] in
      Fun.protect
        ~finally:(fun () -> Exec_tap.disable ())
        (fun () ->
          Exec_tap.enable ~writer:(fun line -> captured := line :: !captured);
          match Repo_git.status_summary ~repository:repo () with
          | Error e -> Alcotest.fail ("status failed: " ^ e)
          | Ok _ ->
              let joined = String.concat "\n" (List.rev !captured) in
              Alcotest.(check bool)
                "uses --no-optional-locks" true
                (String_util.contains_substring joined "--no-optional-locks");
	              Alcotest.(check bool)
	                "sets GIT_OPTIONAL_LOCKS env key" true
	                (String_util.contains_substring joined "\"GIT_OPTIONAL_LOCKS\"")))

let test_status_files_preserve_paths_and_axes () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      (match run_cmd ~cwd:source [ "git"; "checkout"; "-b"; "status-files" ] with
       | Ok () -> ()
       | Error e -> Alcotest.fail ("git checkout status-files failed: " ^ e));
      let tracked_name = "tracked name.txt" in
      let tracked = Filename.concat source tracked_name in
      write_file tracked "committed\n";
      (match run_cmd ~cwd:source [ "git"; "add"; tracked_name ] with
       | Ok () -> ()
       | Error e -> Alcotest.fail ("git add failed: " ^ e));
      (match run_cmd ~cwd:source [ "git"; "commit"; "-m"; "tracked path" ] with
       | Ok () -> ()
       | Error e -> Alcotest.fail ("git commit failed: " ^ e));
      write_file tracked "modified\n";
      write_file (Filename.concat source "새 파일.txt") "new\n";
      match Repo_git.status_files_at ~local_path:source () with
      | Error e -> Alcotest.fail ("status files failed: " ^ e)
      | Ok files ->
          let find path = List.find_opt (fun row -> row.Repo_git.path = path) files in
          (match find tracked_name with
           | None -> Alcotest.fail "tracked path missing"
           | Some row ->
               Alcotest.(check bool) "tracked is unstaged" true row.unstaged;
               Alcotest.(check bool) "tracked is not staged" false row.staged);
          (match find "새 파일.txt" with
           | None -> Alcotest.fail "untracked UTF-8 path missing"
           | Some row ->
               Alcotest.(check bool) "new path is untracked" true row.untracked;
               Alcotest.(check bool) "new path is not conflicted" false
                 row.conflicted))

let test_origin_head_branch_preserves_slash_branch () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      (match run_cmd ~cwd:source [ "git"; "branch"; "release/v1" ] with
       | Ok () -> ()
       | Error e -> Alcotest.fail ("git branch release/v1 failed: " ^ e));
      (match
         run_cmd
           ~cwd:source
           [ "git"; "update-ref"; "refs/remotes/origin/release/v1"; "HEAD" ]
       with
       | Ok () -> ()
       | Error e -> Alcotest.fail ("git update-ref origin/release/v1 failed: " ^ e));
      (match
         run_cmd
           ~cwd:source
           [ "git"
           ; "symbolic-ref"
           ; "refs/remotes/origin/HEAD"
           ; "refs/remotes/origin/release/v1"
           ]
       with
       | Ok () -> ()
       | Error e -> Alcotest.fail ("git origin HEAD failed: " ^ e));
      match Repo_git.origin_head_branch ~local_path:source with
      | Ok branch -> Alcotest.(check string) "origin HEAD branch" "release/v1" branch
      | Error e -> Alcotest.fail ("origin_head_branch failed: " ^ e))

let () =
  Alcotest.run "Repo_git"
    [
      ( "clone",
        [
          Alcotest.test_case "ok" `Quick test_clone_ok;
          Alcotest.test_case "bad_url" `Quick test_clone_bad_url;
        ] );
      ( "get_branches",
        [ Alcotest.test_case "returns branches" `Quick test_get_branches ] );
      ( "get_origin_url",
        [ Alcotest.test_case "returns configured origin" `Quick test_get_origin_url
        ; Alcotest.test_case
            "reports missing origin as typed absence"
            `Quick
            test_get_origin_url_reports_missing_without_text_matching
        ; Alcotest.test_case
            "times out on stalled config"
            `Slow
            test_get_origin_url_times_out_on_stalled_config
        ; Alcotest.test_case
            "uses read-only git environment"
            `Quick
            test_get_origin_url_uses_read_only_git_env
        ] );
      ( "fetch", [ Alcotest.test_case "returns remotes" `Quick test_fetch ] );
      ( "get_recent_commits",
        [ Alcotest.test_case "returns commits" `Quick test_get_recent_commits ] );
	      ( "status_summary",
	        [
	          Alcotest.test_case "counts porcelain rows" `Quick
	            test_status_summary_counts_porcelain_rows;
	          Alcotest.test_case "uses read-only git conventions" `Quick
	            test_status_summary_uses_read_only_git_conventions;
	          Alcotest.test_case "lists exact changed paths and axes" `Quick
	            test_status_files_preserve_paths_and_axes;
	        ] );
	      ( "origin_head_branch",
	        [
	          Alcotest.test_case "preserves slash branch" `Quick
	            test_origin_head_branch_preserves_slash_branch;
	        ] );
	    ]
