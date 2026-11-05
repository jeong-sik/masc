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

(* Long enough that returning before it proves the budget cut the git off,
   rather than the fake exiting on its own. *)
let stalled_git_sleep_sec = 30

(* The elapsed reading and the budget are taken from two different clocks, so
   a run that waited the whole budget can measure a hair under it. *)
let timing_slack_sec = 1.0

let test_get_origin_url_times_out_on_stalled_config () =
  with_temp_dir (fun tmp ->
      let fake_bin = Filename.concat tmp "bin" in
      Unix.mkdir fake_bin 0o755;
      let fake_git = Filename.concat fake_bin "git" in
      write_file fake_git (Printf.sprintf "#!/bin/sh\nsleep %d\n" stalled_git_sleep_sec);
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
              (* The constructor is the classification. Repo_git reads it off
                 Process_eio.exit_reason_of_status and puts the exit status,
                 not a duration, in the detail -- #28651 took the number out
                 of here precisely so the two modules would stop agreeing by
                 coincidence. What is left to check is which call was cut and
                 how long it took. *)
              let elapsed = Unix.gettimeofday () -. started_at in
              Alcotest.(check bool)
                "the detail names the call that timed out"
                true
                (String_util.contains_substring error "git remote get-url origin");
              (* Not the timeout's own number typed again. The budget belongs
                 to Repo_git, so the bound reads it there; the upper bound is
                 the stalled git's own sleep, which returning before proves
                 the budget cut it. *)
              Alcotest.(check bool)
                "waited for the inspection budget"
                true
                (elapsed >= Repo_git.inspection_timeout_sec -. timing_slack_sec);
              Alcotest.(check bool)
                "returned without waiting the stalled git out"
                true
                (elapsed < float_of_int stalled_git_sleep_sec)
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
                (List.mem "origin/main" remotes);
              let common_dir = Filename.concat dest ".git" in
              let oid =
                match Repo_git.run_git ~cwd:dest [ "rev-parse"; "origin/main" ] with
                | Ok [ oid ] -> oid
                | _ -> Alcotest.fail "origin/main OID unavailable"
              in
              (match Repo_fetch_observation.read ~common_dir with
               | Some receipt ->
                 Alcotest.(check string) "no-op fetch receipt ref" "origin/main" receipt.target_ref;
                 Alcotest.(check string) "no-op fetch receipt OID" oid receipt.oid;
                 Alcotest.(check string) "no-op fetch receipt URL" source receipt.origin_url;
                 Alcotest.(check bool) "recorded completion time" true
                   (receipt.observed_at_unix > 1600000000)
               | None -> Alcotest.fail "no-op fetch did not write a receipt")))

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

let nul_join records = String.concat "\000" records ^ "\000"

let test_branch_status_reads_tracking_counts () =
  let output =
    nul_join
      [ "# branch.oid 0123"
      ; "# branch.head feat/x"
      ; "# branch.upstream origin/feat/x"
      ; "# branch.ab +3 -1"
      ; "1 .M N... 100644 100644 100644 aaa bbb lib/a.ml"
      ]
  in
  match Repo_git.branch_status_of_porcelain_v2_z output with
  | Ok
      (Repo_git.On_branch
         { name = "feat/x"
         ; upstream = Tracking { upstream = "origin/feat/x"; ahead = 3; behind = 1 }
         }) ->
      ()
  | Ok _ -> Alcotest.fail "unexpected branch status"
  | Error e -> Alcotest.fail ("branch status failed: " ^ e)

let test_branch_status_without_counts_is_not_zero () =
  let no_upstream = nul_join [ "# branch.oid 0123"; "# branch.head main" ] in
  let gone =
    nul_join
      [ "# branch.oid 0123"; "# branch.head main"; "# branch.upstream origin/main" ]
  in
  (match Repo_git.branch_status_of_porcelain_v2_z no_upstream with
   | Ok (Repo_git.On_branch { name = "main"; upstream = No_upstream }) -> ()
   | _ -> Alcotest.fail "no upstream header must read as No_upstream");
  match Repo_git.branch_status_of_porcelain_v2_z gone with
  | Ok (Repo_git.On_branch { name = "main"; upstream = Upstream_gone "origin/main" }) ->
      ()
  | _ -> Alcotest.fail "an upstream without counts must read as Upstream_gone"

let test_branch_status_detached_and_malformed () =
  (match
     Repo_git.branch_status_of_porcelain_v2_z
       (nul_join [ "# branch.oid 0123"; "# branch.head (detached)" ])
   with
   | Ok Repo_git.Detached -> ()
   | _ -> Alcotest.fail "(detached) must read as Detached");
  let reject label output =
    Alcotest.(check bool) label true
      (Result.is_error (Repo_git.branch_status_of_porcelain_v2_z output))
  in
  reject "no head header" (nul_join [ "# branch.oid 0123" ]);
  reject "empty output" "";
  reject "non-numeric counts"
    (nul_join
       [ "# branch.head main"; "# branch.upstream origin/main"; "# branch.ab +x -1" ]);
  reject "counts in the wrong order"
    (nul_join
       [ "# branch.head main"; "# branch.upstream origin/main"; "# branch.ab -1 +1" ])

let test_branch_status_at_reads_a_checkout () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      (match run_cmd ~cwd:source [ "git"; "checkout"; "-b"; "branch-status" ] with
       | Ok () -> ()
       | Error e -> Alcotest.fail ("git checkout failed: " ^ e));
      (match Repo_git.branch_status_at ~local_path:source () with
       | Ok (Repo_git.On_branch { name = "branch-status"; upstream = No_upstream }) -> ()
       | Ok _ -> Alcotest.fail "a fresh local branch has no upstream"
       | Error e -> Alcotest.fail ("branch status failed: " ^ e));
      (match run_cmd ~cwd:source [ "git"; "checkout"; "--detach" ] with
       | Ok () -> ()
       | Error e -> Alcotest.fail ("git checkout --detach failed: " ^ e));
      match Repo_git.branch_status_at ~local_path:source () with
      | Ok Repo_git.Detached -> ()
      | Ok _ -> Alcotest.fail "a detached checkout must read as Detached"
      | Error e -> Alcotest.fail ("branch status failed: " ^ e))

let branch_record ?(head = " ") ?(upstream = "") ?(track = "") ?(epoch = "1787000000")
    ?(subject = "subject") name =
  String.concat "\000" [ head; name; upstream; track; epoch; subject ]

let branch_rows records = String.concat "\n" records ^ "\n"

let test_branch_rows_read_every_upstream_relation () =
  let output =
    branch_rows
      [ branch_record ~head:"*" ~upstream:"origin/main" "main"
      ; branch_record ~upstream:"origin/a" ~track:"ahead 2" "a"
      ; branch_record ~upstream:"origin/b" ~track:"behind 1" "b"
      ; branch_record ~upstream:"origin/c" ~track:"ahead 2, behind 1" "feat/c"
      ; branch_record ~upstream:"origin/d" ~track:"gone" "d"
      ; branch_record ~subject:"fix: tab\tand : colon" "e"
      ]
  in
  match Repo_git.branch_list_of_for_each_ref ~max_entries:10 output with
  | Error e -> Alcotest.fail e
  | Ok { bl_entries; bl_truncated } ->
      Alcotest.(check bool) "not truncated" false bl_truncated;
      let by_name name =
        match List.find_opt (fun (e : Repo_git.branch_entry) -> String.equal e.be_name name) bl_entries with
        | Some entry -> entry
        | None -> Alcotest.fail ("missing " ^ name)
      in
      Alcotest.(check (list string)) "order is git's"
        [ "main"; "a"; "b"; "feat/c"; "d"; "e" ]
        (List.map (fun (e : Repo_git.branch_entry) -> e.be_name) bl_entries);
      Alcotest.(check bool) "the HEAD mark" true (by_name "main").be_current;
      Alcotest.(check bool) "others are not current" false (by_name "a").be_current;
      Alcotest.(check bool) "in step is zero counts, not no upstream" true
        ((by_name "main").be_upstream
         = Repo_git.Tracking { upstream = "origin/main"; ahead = 0; behind = 0 });
      Alcotest.(check bool) "ahead only" true
        ((by_name "a").be_upstream
         = Repo_git.Tracking { upstream = "origin/a"; ahead = 2; behind = 0 });
      Alcotest.(check bool) "behind only" true
        ((by_name "b").be_upstream
         = Repo_git.Tracking { upstream = "origin/b"; ahead = 0; behind = 1 });
      Alcotest.(check bool) "both" true
        ((by_name "feat/c").be_upstream
         = Repo_git.Tracking { upstream = "origin/c"; ahead = 2; behind = 1 });
      Alcotest.(check bool) "gone keeps the name" true
        ((by_name "d").be_upstream = Repo_git.Upstream_gone "origin/d");
      Alcotest.(check bool) "no upstream" true
        ((by_name "e").be_upstream = Repo_git.No_upstream);
      Alcotest.(check string) "subject keeps tabs and colons" "fix: tab\tand : colon"
        (by_name "e").be_subject;
      Alcotest.(check int) "commit time" 1787000000 (by_name "e").be_commit_epoch

let test_branch_rows_refuse_what_they_cannot_read () =
  let reject label output =
    Alcotest.(check bool) label true
      (Result.is_error (Repo_git.branch_list_of_for_each_ref ~max_entries:5 output))
  in
  reject "five fields" "*\000main\000\000\0001787000000\n";
  reject "an unknown HEAD mark" (branch_rows [ branch_record ~head:"?" "main" ]);
  reject "an empty name" (branch_rows [ branch_record "" ]);
  reject "a non-numeric time" (branch_rows [ branch_record ~epoch:"yesterday" "main" ]);
  reject "a negative time" (branch_rows [ branch_record ~epoch:"-1" "main" ]);
  reject "an unreadable track" (branch_rows [ branch_record ~upstream:"o/m" ~track:"ahead x" "m" ]);
  reject "a zero count" (branch_rows [ branch_record ~upstream:"o/m" ~track:"ahead 0" "m" ]);
  reject "behind before ahead"
    (branch_rows [ branch_record ~upstream:"o/m" ~track:"behind 1, ahead 2" "m" ]);
  reject "two aheads" (branch_rows [ branch_record ~upstream:"o/m" ~track:"ahead 1, ahead 2" "m" ]);
  reject "counts without an upstream" (branch_rows [ branch_record ~track:"ahead 2" "m" ]);
  reject "gone without an upstream" (branch_rows [ branch_record ~track:"gone" "m" ]);
  Alcotest.(check bool) "max_entries below one is refused" true
    (Result.is_error (Repo_git.branch_list_of_for_each_ref ~max_entries:0 ""));
  Alcotest.(check bool) "no branches is an empty list" true
    (match Repo_git.branch_list_of_for_each_ref ~max_entries:5 "" with
     | Ok { bl_entries = []; bl_truncated = false } -> true
     | Ok _ | Error _ -> false);
  let three = branch_rows [ branch_record "a"; branch_record "b"; branch_record "c" ] in
  Alcotest.(check bool) "a record past the limit marks the list cut" true
    (match Repo_git.branch_list_of_for_each_ref ~max_entries:2 three with
     | Ok { bl_entries = [ _; _ ]; bl_truncated = true } -> true
     | Ok _ | Error _ -> false)

let test_branches_at_reads_a_checkout () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let base =
        match Repo_git.branch_status_at ~local_path:source () with
        | Ok (Repo_git.On_branch { name; _ }) -> name
        | Ok Repo_git.Detached | Error _ -> Alcotest.fail "fixture has no branch"
      in
      let git args =
        match run_cmd ~cwd:source ("git" :: args) with
        | Ok () -> ()
        | Error e -> Alcotest.fail ("git " ^ String.concat " " args ^ " failed: " ^ e)
      in
      git [ "checkout"; "-b"; "feat/tracked" ];
      write_file (Filename.concat source "extra.txt") "extra\n";
      git [ "add"; "extra.txt" ];
      git [ "commit"; "-m"; "work on the branch" ];
      git [ "branch"; "--set-upstream-to=" ^ base ];
      git [ "branch"; "loose" ; base ];
      match Repo_git.branches_at ~local_path:source ~max_entries:10 () with
      | Error e -> Alcotest.fail ("branches failed: " ^ e)
      | Ok { bl_entries; bl_truncated } ->
          Alcotest.(check bool) "not truncated" false bl_truncated;
          let find name =
            List.find_opt (fun (e : Repo_git.branch_entry) -> String.equal e.be_name name) bl_entries
          in
          (match find "feat/tracked" with
           | Some entry ->
               Alcotest.(check bool) "the checked-out branch" true entry.be_current;
               Alcotest.(check string) "its tip subject" "work on the branch" entry.be_subject;
               Alcotest.(check bool) "one commit ahead of its upstream" true
                 (entry.be_upstream
                  = Repo_git.Tracking { upstream = base; ahead = 1; behind = 0 })
           | None -> Alcotest.fail "feat/tracked is missing");
          (match find "loose" with
           | Some entry ->
               Alcotest.(check bool) "another branch is not current" false entry.be_current;
               Alcotest.(check bool) "a fresh branch has no upstream" true
                 (entry.be_upstream = Repo_git.No_upstream)
           | None -> Alcotest.fail "loose is missing");
          Alcotest.(check bool) "the base branch is listed" true (Option.is_some (find base)))

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

let test_file_paths_preserve_exact_names_and_ignore_policy () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let tracked = "tracked ignored.tmp" in
      write_file (Filename.concat source ".gitignore") "*.tmp\n";
      write_file (Filename.concat source tracked) "tracked\n";
      (match run_cmd ~cwd:source [ "git"; "add"; "--force"; "--"; tracked ] with
       | Ok () -> ()
       | Error e -> Alcotest.fail e);
      let fresh = [ "-leading.ml"; "space name.ml"; "새 파일.ml"; "line\nbreak.ml" ] in
      List.iter (fun path -> write_file (Filename.concat source path) "new\n") fresh;
      write_file (Filename.concat source "hidden.tmp") "ignored\n";
      match Repo_git.file_paths_at ~local_path:source () with
      | Error detail -> Alcotest.fail detail
      | Ok paths ->
          Alcotest.(check (list string)) "exact tracked and nonignored paths"
            (List.sort String.compare (".gitignore" :: tracked :: fresh)) paths)

let test_file_paths_report_git_failure () =
  with_temp_dir (fun local_path ->
      match Repo_git.file_paths_at ~local_path () with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "a nonrepository must not become an empty catalog")

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
      ( "file_paths",
        [ Alcotest.test_case "preserves exact names and ignore policy" `Quick
            test_file_paths_preserve_exact_names_and_ignore_policy
        ; Alcotest.test_case "reports Git failure" `Quick
            test_file_paths_report_git_failure
        ] );
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
	      ( "branch_status",
	        [
	          Alcotest.test_case "reads tracking counts" `Quick
	            test_branch_status_reads_tracking_counts;
	          Alcotest.test_case "missing counts are not zero" `Quick
	            test_branch_status_without_counts_is_not_zero;
	          Alcotest.test_case "detached head and malformed headers" `Quick
	            test_branch_status_detached_and_malformed;
	          Alcotest.test_case "reads a real checkout" `Quick
	            test_branch_status_at_reads_a_checkout;
	        ] );
	      ( "branches",
	        [
	          Alcotest.test_case "reads every upstream relation" `Quick
	            test_branch_rows_read_every_upstream_relation;
	          Alcotest.test_case "refuses what it cannot read" `Quick
	            test_branch_rows_refuse_what_they_cannot_read;
	          Alcotest.test_case "reads a real checkout" `Quick
	            test_branches_at_reads_a_checkout;
	        ] );
	      ( "origin_head_branch",
	        [
	          Alcotest.test_case "preserves slash branch" `Quick
	            test_origin_head_branch_preserves_slash_branch;
	        ] );
	    ]
