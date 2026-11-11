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
     | Ok _ | Error _ -> false);
  let idle_current =
    branch_rows
      [ branch_record "a"; branch_record "b"; branch_record "c"
      ; branch_record ~head:"*" "idle" ]
  in
  Alcotest.(check (option (list string))) "a cut keeps the checked-out branch last"
    (Some [ "a"; "b"; "idle" ])
    (match Repo_git.branch_list_of_for_each_ref ~max_entries:2 idle_current with
     | Ok { bl_entries; bl_truncated = true } ->
         Some (List.map (fun (e : Repo_git.branch_entry) -> e.be_name) bl_entries)
     | Ok { bl_truncated = false; _ } | Error _ -> None)

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

(* [git worktree list --porcelain -z] writes each field with a closing NUL and
   closes a record with one more NUL. *)
let porcelain records =
  String.concat "" (List.map (fun fields -> String.concat "\000" fields ^ "\000\000") records)

let worktree_head = String.make 40 'a'

let test_worktree_rows_read_every_state () =
  let output =
    porcelain
      [ [ "worktree /host/repo"; "HEAD " ^ worktree_head; "branch refs/heads/main" ]
      ; [ "worktree /host/trees/linked"; "HEAD " ^ worktree_head; "detached"
        ; "locked kept for a diagnostic" ]
      ; [ "worktree /host/trees/bare"; "bare" ]
      ; [ "worktree /host/trees/gone"; "HEAD " ^ worktree_head
        ; "branch refs/heads/feat/a"; "prunable gitdir file points to nothing" ]
      ; [ "worktree /host/trees/locked-plain"; "HEAD " ^ worktree_head; "detached"; "locked" ]
      ]
  in
  match Repo_git.worktree_list_of_porcelain ~max_entries:10 output with
  | Error e -> Alcotest.fail ("worktree rows failed: " ^ e)
  | Ok { wl_entries; wl_truncated } ->
      Alcotest.(check bool) "not truncated" false wl_truncated;
      Alcotest.(check (list string)) "only the last path component is kept"
        [ "repo"; "linked"; "bare"; "gone"; "locked-plain" ]
        (List.map (fun (e : Repo_git.worktree_entry) -> e.wt_name) wl_entries);
      Alcotest.(check (list bool)) "only the first record is the main worktree"
        [ true; false; false; false; false ]
        (List.map (fun (e : Repo_git.worktree_entry) -> e.wt_main) wl_entries);
      Alcotest.(check (list bool)) "locked, with or without a reason"
        [ false; true; false; false; true ]
        (List.map (fun (e : Repo_git.worktree_entry) -> e.wt_locked) wl_entries);
      Alcotest.(check (list bool)) "prunable"
        [ false; false; false; true; false ]
        (List.map (fun (e : Repo_git.worktree_entry) -> e.wt_prunable) wl_entries);
      Alcotest.(check bool) "branch, detached and bare are told apart" true
        (List.map (fun (e : Repo_git.worktree_entry) -> e.wt_state) wl_entries
         = [ Repo_git.Worktree_branch "main"; Repo_git.Worktree_detached
           ; Repo_git.Worktree_bare; Repo_git.Worktree_branch "feat/a"
           ; Repo_git.Worktree_detached ]);
      Alcotest.(check bool) "a bare entry has no HEAD, the others do" true
        (List.map (fun (e : Repo_git.worktree_entry) -> e.wt_head) wl_entries
         = [ Some worktree_head; Some worktree_head; None; Some worktree_head
           ; Some worktree_head ])

let test_worktree_rows_refuse_what_they_cannot_read () =
  let head = "HEAD " ^ worktree_head in
  let refused label records =
    Alcotest.(check bool) label true
      (Result.is_error (Repo_git.worktree_list_of_porcelain ~max_entries:5 (porcelain records)))
  in
  refused "no path" [ [ head; "detached" ] ];
  refused "an empty path" [ [ "worktree "; head; "detached" ] ];
  refused "no checkout state" [ [ "worktree /a/x"; head ] ];
  refused "two checkout states" [ [ "worktree /a/x"; head; "detached"; "branch refs/heads/b" ] ];
  refused "a non-branch ref" [ [ "worktree /a/x"; head; "branch refs/tags/v1" ] ];
  refused "an empty branch name" [ [ "worktree /a/x"; head; "branch refs/heads/" ] ];
  refused "no HEAD on a non-bare entry" [ [ "worktree /a/x"; "detached" ] ];
  refused "HEAD named twice" [ [ "worktree /a/x"; head; head; "detached" ] ];
  refused "a HEAD that is not hex" [ [ "worktree /a/x"; "HEAD not-a-commit"; "detached" ] ];
  refused "an unknown field" [ [ "worktree /a/x"; head; "detached"; "future-field 1" ] ];
  refused "a bad record after a good one"
    [ [ "worktree /a/x"; head; "detached" ]; [ "worktree /a/y"; head ] ];
  (* A stream cut inside a record has no closing NUL after its last field. *)
  Alcotest.(check bool) "a stream cut inside a record" true
    (Result.is_error
       (Repo_git.worktree_list_of_porcelain ~max_entries:5
          ("worktree /a/x\000HEAD " ^ worktree_head ^ "\000detached")));
  Alcotest.(check bool) "max_entries of zero" true
    (Result.is_error (Repo_git.worktree_list_of_porcelain ~max_entries:0 ""));
  (match Repo_git.worktree_list_of_porcelain ~max_entries:5 "" with
   | Ok { wl_entries = []; wl_truncated = false } -> ()
   | Ok _ | Error _ -> Alcotest.fail "empty output is an empty list");
  let three =
    porcelain
      (List.map (fun name -> [ "worktree /a/" ^ name; head; "detached" ]) [ "one"; "two"; "three" ])
  in
  match Repo_git.worktree_list_of_porcelain ~max_entries:2 three with
  | Ok { wl_entries; wl_truncated = true } ->
      Alcotest.(check int) "keeps max_entries" 2 (List.length wl_entries)
  | Ok _ | Error _ -> Alcotest.fail "a third record must mark the list truncated"

let test_worktrees_at_reads_a_checkout () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let git args =
        match run_cmd ~cwd:source ("git" :: args) with
        | Ok () -> ()
        | Error e -> Alcotest.fail ("git " ^ String.concat " " args ^ " failed: " ^ e)
      in
      let linked = Filename.concat tmp "linked-tree" in
      git [ "worktree"; "add"; linked; "-b"; "linked-branch" ];
      git [ "worktree"; "lock"; linked; "--reason"; "kept by a test" ];
      match Repo_git.worktrees_at ~local_path:source ~max_entries:10 () with
      | Error e -> Alcotest.fail ("worktrees failed: " ^ e)
      | Ok { wl_entries; wl_truncated } ->
          Alcotest.(check bool) "not truncated" false wl_truncated;
          (match wl_entries with
           | [ main; second ] ->
               Alcotest.(check string) "main worktree name" "source" main.wt_name;
               Alcotest.(check bool) "the first entry is the main worktree" true main.wt_main;
               Alcotest.(check string) "linked worktree name" "linked-tree" second.wt_name;
               Alcotest.(check bool) "the linked one is not main" false second.wt_main;
               Alcotest.(check bool) "the linked one is locked" true second.wt_locked;
               Alcotest.(check bool) "the linked one is on its new branch" true
                 (second.wt_state = Repo_git.Worktree_branch "linked-branch")
           | other ->
               Alcotest.fail
                 (Printf.sprintf "expected two worktrees, got %d" (List.length other))))

let grep_rows rows = String.concat "\n" rows ^ "\n"
let grep_row path line text = Printf.sprintf "%s\000%d\000%s" path line text

let test_grep_rows_keep_the_first_matches_and_say_when_cut () =
  let output =
    grep_rows
      [ grep_row "lib/a.ml" 3 "let x = 1"
      ; grep_row "lib/b file.ml" 10 "tab\tand : colon"
      ; grep_row "lib/c.ml" 1 "third"
      ]
  in
  (match Repo_git.grep_result_of_z_output ~max_matches:5 output with
   | Ok { gr_matches = [ first; second; _ ]; gr_truncated = false } ->
       Alcotest.(check string) "path" "lib/a.ml" first.gm_path;
       Alcotest.(check int) "line" 3 first.gm_line;
       Alcotest.(check string) "a path keeps its space" "lib/b file.ml" second.gm_path;
       Alcotest.(check string) "text keeps tabs and colons" "tab\tand : colon"
         second.gm_text
   | Ok _ -> Alcotest.fail "expected three untruncated matches"
   | Error e -> Alcotest.fail e);
  match Repo_git.grep_result_of_z_output ~max_matches:2 output with
  | Ok { gr_matches = [ _; _ ]; gr_truncated = true } -> ()
  | Ok _ -> Alcotest.fail "a third row must mark the answer truncated"
  | Error e -> Alcotest.fail e

let test_grep_rows_survive_a_newline_in_a_path () =
  let output =
    grep_rows [ grep_row "b\nc.txt" 4 "needle k"; grep_row "lib/a.ml" 1 "needle" ]
  in
  match Repo_git.grep_result_of_z_output ~max_matches:5 output with
  | Ok { gr_matches = [ first; second ]; gr_truncated = false } ->
      Alcotest.(check string) "a path keeps its newline" "b\nc.txt" first.gm_path;
      Alcotest.(check int) "line" 4 first.gm_line;
      Alcotest.(check string) "text" "needle k" first.gm_text;
      Alcotest.(check string) "next row" "lib/a.ml" second.gm_path
  | Ok _ -> Alcotest.fail "expected two untruncated matches"
  | Error e -> Alcotest.fail e

let test_a_file_at_the_per_file_cap_marks_the_answer_cut () =
  let rows count path = List.init count (fun i -> grep_row path (i + 1) "needle") in
  let truncated output =
    match Repo_git.grep_result_of_z_output ~max_matches:100 output with
    | Ok { gr_truncated; _ } -> gr_truncated
    | Error e -> Alcotest.fail e
  in
  Alcotest.(check bool) "19 rows in one file" false (truncated (grep_rows (rows 19 "a.ml")));
  Alcotest.(check bool) "20 rows in one file" true (truncated (grep_rows (rows 20 "a.ml")));
  Alcotest.(check bool) "20 rows spread over two files" false
    (truncated (grep_rows (rows 10 "a.ml" @ rows 10 "b.ml")))

let test_grep_rows_refuse_what_they_cannot_read () =
  let reject label output =
    Alcotest.(check bool) label true
      (Result.is_error (Repo_git.grep_result_of_z_output ~max_matches:5 output))
  in
  reject "a row without separators" "[... output truncated ...]\n";
  reject "a row without a line separator" "lib/a.ml\0005\n";
  reject "a non-numeric line" "lib/a.ml\000one\000text\n";
  reject "line zero" "lib/a.ml\0000\000text\n";
  reject "an empty path" "\0001\000text\n";
  Alcotest.(check bool) "a marker after the kept rows is not reached" true
    (Result.is_ok
       (Repo_git.grep_result_of_z_output ~max_matches:1
          (grep_rows [ grep_row "lib/a.ml" 1 "x"; "[... output truncated ...]" ])));
  Alcotest.(check bool) "no rows is an empty answer" true
    (match Repo_git.grep_result_of_z_output ~max_matches:5 "" with
     | Ok { gr_matches = []; gr_truncated = false } -> true
     | Ok _ | Error _ -> false);
  Alcotest.(check bool) "max_matches below one is refused" true
    (Result.is_error (Repo_git.grep_result_of_z_output ~max_matches:0 ""))

let test_grep_at_reads_a_checkout () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      (match run_cmd ~cwd:source [ "git"; "checkout"; "-b"; "grep-test" ] with
       | Ok () -> ()
       | Error e -> Alcotest.fail ("git checkout grep-test failed: " ^ e));
      let git args =
        match run_cmd ~cwd:source ("git" :: args) with
        | Ok () -> ()
        | Error e -> Alcotest.fail ("git " ^ String.concat " " args ^ " failed: " ^ e)
      in
      Unix.mkdir (Filename.concat source "lib") 0o755;
      write_file (Filename.concat source "lib/a file.ml") "first\nNeedle here\nlast\n";
      write_file (Filename.concat source "top.txt") "a needle at the top\n--flag needle\n";
      write_file (Filename.concat source ".gitignore") "ignored.txt\nforced.txt\n";
      write_file (Filename.concat source "forced.txt") "tracked despite an ignore rule\n";
      git [ "add"; "lib/a file.ml"; "top.txt"; ".gitignore" ];
      git [ "add"; "--force"; "--"; "forced.txt" ];
      git [ "commit"; "-m"; "files" ];
      write_file (Filename.concat source "untracked.txt") "needle untracked\n";
      write_file (Filename.concat source "ignored.txt") "needle ignored\n";
      let search ?(pathspec = "") ?(ignore_case = false) pattern =
        match
          Repo_git.grep_at ~local_path:source ~pathspec ~pattern ~ignore_case
            ~max_matches:50 ()
        with
        | Ok result -> result
        | Error e -> Alcotest.fail ("grep failed: " ^ e)
      in
      let paths result = List.map (fun m -> m.Repo_git.gm_path) result.Repo_git.gr_matches in
      Alcotest.(check (list string)) "case sensitive finds only the lower-case rows"
        [ "top.txt"; "top.txt"; "untracked.txt" ]
        (List.sort String.compare (paths (search "needle")));
      Alcotest.(check (list string)) "ignore_case adds the capitalised row, and never an ignored file"
        [ "lib/a file.ml"; "top.txt"; "top.txt"; "untracked.txt" ]
        (List.sort String.compare (paths (search ~ignore_case:true "needle")));
      Alcotest.(check (list string)) "a tracked file stays searchable when an ignore rule matches it"
        [ "forced.txt" ]
        (paths (search "despite an ignore rule"));
      Alcotest.(check (list string)) "a pathspec limits the search to that directory"
        [ "lib/a file.ml" ]
        (paths (search ~pathspec:"lib" ~ignore_case:true "needle"));
      (match (search ~pathspec:"lib" ~ignore_case:true "needle").gr_matches with
       | [ m ] ->
           Alcotest.(check int) "line numbers are 1-based" 2 m.gm_line;
           Alcotest.(check string) "the line text is returned" "Needle here" m.gm_text
       | _ -> Alcotest.fail "expected one match under lib");
      Alcotest.(check int) "a pattern that looks like an option is searched, not run" 1
        (List.length (search "--flag").gr_matches);
      let none = search "no-such-text-anywhere" in
      Alcotest.(check bool) "no match is an empty answer, not an error" true
        (none.gr_matches = [] && not none.gr_truncated);
      Alcotest.(check bool) "an empty pattern is refused" true
        (Result.is_error
           (Repo_git.grep_at ~local_path:source ~pathspec:"" ~pattern:""
              ~ignore_case:false ~max_matches:5 ())))

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
	      ( "worktrees",
	        [
	          Alcotest.test_case "reads every state" `Quick
	            test_worktree_rows_read_every_state;
	          Alcotest.test_case "refuses what it cannot read" `Quick
	            test_worktree_rows_refuse_what_they_cannot_read;
	          Alcotest.test_case "reads a real checkout" `Quick
	            test_worktrees_at_reads_a_checkout;
	        ] );
	      ( "grep",
	        [
	          Alcotest.test_case "keeps the first matches and says when cut" `Quick
	            test_grep_rows_keep_the_first_matches_and_say_when_cut;
	          Alcotest.test_case "survives a newline in a path" `Quick
	            test_grep_rows_survive_a_newline_in_a_path;
	          Alcotest.test_case "a file at the per-file cap marks the answer cut" `Quick
	            test_a_file_at_the_per_file_cap_marks_the_answer_cut;
	          Alcotest.test_case "refuses what it cannot read" `Quick
	            test_grep_rows_refuse_what_they_cannot_read;
	          Alcotest.test_case "reads a real checkout" `Quick
	            test_grep_at_reads_a_checkout;
	        ] );
	    ]
