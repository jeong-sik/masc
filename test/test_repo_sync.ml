(** Tests for Repo_sync module *)

open Repo_manager_types

module Mcp_server = Masc.Mcp_server

let sample_repo ?(auto_sync = true) ?(sync_interval = 300) ?(updated_at = Int64.of_int 1700000000) id =
  {
    id;
    name = "repo-" ^ id;
    url = "https://github.com/test/" ^ id;
    local_path = "repos/" ^ id;
    aliases = [];
    default_branch = "main";
    keepers = [];
    status = Active;
    auto_sync;
    sync_interval;
    created_at = Int64.of_int 1700000000;
    updated_at;
  }

let test_should_sync_auto_sync_disabled () =
  let repo = sample_repo ~auto_sync:false "r1" in
  let now = Int64.of_int 1700001000 in
  Alcotest.(check bool) "auto_sync=false means no sync" false (Repo_sync.should_sync repo ~now)

let test_should_sync_interval_not_elapsed () =
  let repo = sample_repo ~auto_sync:true ~sync_interval:300 ~updated_at:(Int64.of_int 1700000000) "r1" in
  let now = Int64.of_int 1700000100 in
  Alcotest.(check bool) "only 100s elapsed < 300s interval" false (Repo_sync.should_sync repo ~now)

let test_should_sync_interval_elapsed () =
  let repo = sample_repo ~auto_sync:true ~sync_interval:300 ~updated_at:(Int64.of_int 1700000000) "r1" in
  let now = Int64.of_int 1700000400 in
  Alcotest.(check bool) "400s elapsed >= 300s interval" true (Repo_sync.should_sync repo ~now)

let test_should_sync_exact_boundary () =
  let repo = sample_repo ~auto_sync:true ~sync_interval:300 ~updated_at:(Int64.of_int 1700000000) "r1" in
  let now = Int64.of_int 1700000300 in
  Alcotest.(check bool) "exactly 300s elapsed" true (Repo_sync.should_sync repo ~now)

let test_should_sync_zero_interval () =
  let repo = sample_repo ~auto_sync:true ~sync_interval:0 ~updated_at:(Int64.of_int 1700000000) "r1" in
  let now = Int64.of_int 1700000000 in
  Alcotest.(check bool) "zero interval, any elapsed >= 0" true (Repo_sync.should_sync repo ~now)

let test_should_sync_large_elapsed () =
  let repo = sample_repo ~auto_sync:true ~sync_interval:60 ~updated_at:(Int64.of_int 1700000000) "r1" in
  let now = Int64.of_int 1700004000 in
  Alcotest.(check bool) "far past interval" true (Repo_sync.should_sync repo ~now)

let test_should_sync_negative_elapsed () =
  let repo = sample_repo ~auto_sync:true ~sync_interval:300 ~updated_at:(Int64.of_int 1700000100) "r1" in
  let now = Int64.of_int 1700000000 in
  Alcotest.(check bool) "now < updated_at means elapsed < 0" false (Repo_sync.should_sync repo ~now)

let test_next_due_at_uses_each_repository_cadence () =
  let short =
    sample_repo ~sync_interval:60 ~updated_at:(Int64.of_int 100) "short"
  in
  let long =
    sample_repo ~sync_interval:300 ~updated_at:(Int64.of_int 100) "long"
  in
  let disabled =
    sample_repo
      ~auto_sync:false
      ~sync_interval:1
      ~updated_at:Int64.zero
      "disabled"
  in
  Alcotest.(check (option int64))
    "earliest declared cadence"
    (Some (Int64.of_int 160))
    (Repo_sync.next_due_at [ long; disabled; short ])

let test_repo_sync_change_notification_wakes_waiter () =
  Eio_main.run (fun _env ->
    let state = Mcp_server.For_testing.create_state ~base_path:"." in
    let revision = Mcp_server.repo_sync_revision state in
    let awakened = Atomic.make false in
    Eio.Fiber.both
      (fun () ->
        Mcp_server.await_repo_sync_change state ~after:revision;
        Atomic.set awakened true)
      (fun () ->
        Eio.Fiber.yield ();
        Mcp_server.notify_repo_sync_change state);
    Alcotest.(check bool)
      "committed change wakes scheduler"
      true
      (Atomic.get awakened))

let with_temp_base_path f =
  let dir = Filename.temp_file "repo_sync_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let config_dir = Filename.concat dir ".masc" in
  Unix.mkdir config_dir 0o755;
  let config_subdir = Filename.concat config_dir "config" in
  Unix.mkdir config_subdir 0o755;
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

let test_sync_all_empty_repos () =
  with_temp_base_path (fun base_path ->
      match Repo_sync.sync_all ~base_path ~now:(Int64.of_int 1700004000) with
      | Ok synced -> Alcotest.(check int) "no repos means no syncs" 0 (List.length synced)
      | Error e -> Alcotest.fail ("unexpected error: " ^ e))

let test_sync_all_no_due_repos () =
  with_temp_base_path (fun base_path ->
      let repos =
        [
          sample_repo ~auto_sync:false "r1";
          sample_repo ~auto_sync:true ~sync_interval:3600 ~updated_at:(Int64.of_int 1700000000) "r2";
        ]
      in
      match Repo_store.save_all ~base_path repos with
      | Error e -> Alcotest.fail ("save failed: " ^ e)
      | Ok () -> (
          match Repo_sync.sync_all ~base_path ~now:(Int64.of_int 1700000100) with
          | Ok synced -> Alcotest.(check int) "no due repos" 0 (List.length synced)
          | Error e -> Alcotest.fail ("sync_all failed: " ^ e)))

(* --- RFC-0210 working-tree advance: real-git fixtures --- *)

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

let git ~cwd args =
  match run_cmd ~cwd ("git" :: "-c" :: "core.hooksPath=/dev/null" :: args) with
  | Ok () -> ()
  | Error e ->
      failwith (Printf.sprintf "git %s failed: %s" (String.concat " " args) e)

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let init_origin path =
  Unix.mkdir path 0o755;
  git ~cwd:path [ "init"; "-b"; "main" ];
  git ~cwd:path [ "config"; "user.email"; "test@example.com" ];
  git ~cwd:path [ "config"; "user.name"; "Test User" ];
  write_file (Filename.concat path "file.txt") "one\n";
  git ~cwd:path [ "add"; "file.txt" ];
  git ~cwd:path [ "commit"; "-m"; "initial" ]

let commit_origin path content message =
  write_file (Filename.concat path "file.txt") content;
  git ~cwd:path [ "add"; "file.txt" ];
  git ~cwd:path [ "commit"; "-m"; message ]

let fixture_repo ~origin ~clone id =
  {
    id;
    name = id;
    url = origin;
    local_path = clone;
    aliases = [];
    default_branch = "main";
    keepers = [];
    status = Active;
    auto_sync = true;
    sync_interval = 300;
    created_at = Int64.of_int 1700000000;
    updated_at = Int64.of_int 1700000000;
  }

(* Creates origin + clone under [base_path], persists the repository record
   (sync_repository updates status through Repo_store), and hands the record
   to [f]. *)
let with_advance_fixture base_path f =
  let origin = Filename.concat base_path "origin" in
  let clone = Filename.concat base_path "clone" in
  init_origin origin;
  git ~cwd:base_path [ "clone"; origin; clone ];
  git ~cwd:clone [ "config"; "user.email"; "test@example.com" ];
  git ~cwd:clone [ "config"; "user.name"; "Test User" ];
  let repo = fixture_repo ~origin ~clone "r1" in
  (match Repo_store.save_all ~base_path [ repo ] with
   | Ok () -> ()
   | Error e -> Alcotest.fail ("save_all failed: " ^ e));
  f ~origin ~clone repo

let test_sync_all_preserves_failure_and_continues () =
  with_temp_base_path (fun base_path ->
    let bad_path = Filename.concat base_path "not-a-repository" in
    Unix.mkdir bad_path 0o755;
    let origin = Filename.concat base_path "origin-for-sync-all" in
    let clone = Filename.concat base_path "clone-for-sync-all" in
    init_origin origin;
    git ~cwd:base_path [ "clone"; origin; clone ];
    let bad =
      { (sample_repo ~sync_interval:0 "bad") with
        url = bad_path
      ; local_path = bad_path
      }
    in
    let good =
      { (sample_repo ~sync_interval:0 "good") with
        url = origin
      ; local_path = clone
      }
    in
    (match Repo_store.save_all ~base_path [ bad; good ] with
     | Ok () -> ()
     | Error reason -> Alcotest.fail ("save_all failed: " ^ reason));
    match Repo_sync.sync_all ~base_path ~now:(Int64.of_int 1700004000) with
    | Error reason -> Alcotest.fail ("sync_all failed: " ^ reason)
    | Ok attempts ->
      Alcotest.(check int) "both due repositories attempted" 2 (List.length attempts);
      let find id =
        List.find_opt
          (fun (attempt : Repo_sync.sync_attempt) ->
            String.equal attempt.repository.id id)
          attempts
      in
      (match find "bad" with
       | Some { result = Error reason; _ } ->
         Alcotest.(check bool)
           "failure reason remains observable"
           true
           (String.trim reason <> "")
       | Some { result = Ok _; _ } ->
         Alcotest.fail "non-repository unexpectedly synced"
       | None -> Alcotest.fail "failed repository attempt was dropped");
      (match find "good" with
       | Some { result = Ok Repo_sync.Already_current; _ } -> ()
       | Some { result = Ok outcome; _ } ->
         Alcotest.failf
           "good repository returned %s"
           (Repo_sync.advance_outcome_label outcome)
       | Some { result = Error reason; _ } ->
         Alcotest.fail ("later repository was stopped: " ^ reason)
       | None -> Alcotest.fail "later repository was not attempted"))

let check_outcome expected actual =
  Alcotest.(check string)
    "advance outcome"
    expected
    (Repo_sync.advance_outcome_label actual)

let sync_ok ~base_path repo =
  match Repo_sync.sync_repository ~base_path repo with
  | Ok outcome -> outcome
  | Error e -> Alcotest.fail ("sync_repository failed: " ^ e)

let test_sync_advances_clean_clone () =
  with_temp_base_path (fun base_path ->
      with_advance_fixture base_path (fun ~origin ~clone repo ->
          commit_origin origin "two\n" "second";
          (match sync_ok ~base_path repo with
           | Repo_sync.Advanced { behind } ->
               Alcotest.(check int) "advanced over one commit" 1 behind
           | other -> check_outcome "advanced" other);
          (match
             Repo_git.ahead_behind ~repository:repo ~target_ref:"origin/main"
           with
           | Ok (behind, ahead) ->
               Alcotest.(check (pair int int))
                 "clone current after advance" (0, 0) (behind, ahead)
           | Error e -> Alcotest.fail e);
          Alcotest.(check string)
            "working tree file advanced" "two\n"
            (read_file (Filename.concat clone "file.txt"))))

let test_sync_fast_forward_suppresses_post_merge_hook () =
  with_temp_base_path (fun base_path ->
      with_advance_fixture base_path (fun ~origin ~clone repo ->
          let marker = Filename.concat clone ".git/post-merge-ran" in
          let hook = Filename.concat clone ".git/hooks/post-merge" in
          write_file hook "#!/bin/sh\nprintf ran > .git/post-merge-ran\n";
          Unix.chmod hook 0o755;
          commit_origin origin "two\n" "second";
          (match sync_ok ~base_path repo with
           | Repo_sync.Advanced { behind } ->
               Alcotest.(check int) "advanced over one commit" 1 behind
           | other -> check_outcome "advanced" other);
          Alcotest.(check string)
            "working tree file advanced" "two\n"
            (read_file (Filename.concat clone "file.txt"));
          Alcotest.(check bool)
            "post-merge hook did not run" false (Sys.file_exists marker)))

let test_sync_already_current () =
  with_temp_base_path (fun base_path ->
      with_advance_fixture base_path (fun ~origin:_ ~clone:_ repo ->
          check_outcome "already_current" (sync_ok ~base_path repo)))

let test_sync_preserves_dirty_tree () =
  with_temp_base_path (fun base_path ->
      with_advance_fixture base_path (fun ~origin ~clone repo ->
          commit_origin origin "two\n" "second";
          write_file (Filename.concat clone "file.txt") "local edit\n";
          (match sync_ok ~base_path repo with
           | Repo_sync.Skipped_dirty { unstaged; _ } ->
               Alcotest.(check bool) "unstaged edit counted" true (unstaged > 0)
           | other -> check_outcome "skipped_dirty" other);
          Alcotest.(check string)
            "local edit preserved" "local edit\n"
            (read_file (Filename.concat clone "file.txt"))))

let test_sync_refuses_diverged_clone () =
  with_temp_base_path (fun base_path ->
      with_advance_fixture base_path (fun ~origin ~clone repo ->
          commit_origin origin "two\n" "second";
          write_file (Filename.concat clone "file.txt") "local commit\n";
          git ~cwd:clone [ "add"; "file.txt" ];
          git ~cwd:clone [ "commit"; "-m"; "local divergence" ];
          (match sync_ok ~base_path repo with
           | Repo_sync.Fast_forward_refused { behind; _ } ->
               Alcotest.(check int) "behind counted" 1 behind
           | other -> check_outcome "fast_forward_refused" other);
          Alcotest.(check string)
            "diverged commit preserved" "local commit\n"
            (read_file (Filename.concat clone "file.txt"))))

let test_sync_skips_non_default_branch () =
  with_temp_base_path (fun base_path ->
      with_advance_fixture base_path (fun ~origin ~clone repo ->
          commit_origin origin "two\n" "second";
          git ~cwd:clone [ "checkout"; "-b"; "feature" ];
          match sync_ok ~base_path repo with
          | Repo_sync.Skipped_not_on_default_branch { current } ->
              Alcotest.(check string) "reports checked-out branch" "feature" current
          | other -> check_outcome "skipped_not_on_default_branch" other))

let () =
  Alcotest.run "Repo_sync"
    [
      ( "should_sync",
        [
          Alcotest.test_case "auto_sync disabled" `Quick test_should_sync_auto_sync_disabled;
          Alcotest.test_case "interval not elapsed" `Quick test_should_sync_interval_not_elapsed;
          Alcotest.test_case "interval elapsed" `Quick test_should_sync_interval_elapsed;
          Alcotest.test_case "exact boundary" `Quick test_should_sync_exact_boundary;
          Alcotest.test_case "zero interval" `Quick test_should_sync_zero_interval;
          Alcotest.test_case "large elapsed" `Quick test_should_sync_large_elapsed;
          Alcotest.test_case "negative elapsed" `Quick test_should_sync_negative_elapsed;
          Alcotest.test_case "earliest repository cadence" `Quick
            test_next_due_at_uses_each_repository_cadence;
        ] );
      ( "sync_all",
        [
          Alcotest.test_case "empty repos" `Quick test_sync_all_empty_repos;
          Alcotest.test_case "no due repos" `Quick test_sync_all_no_due_repos;
          Alcotest.test_case "failure is observable and isolated" `Quick
            test_sync_all_preserves_failure_and_continues;
        ] );
      ( "advance_working_tree",
        [
          Alcotest.test_case "advances clean clone" `Quick test_sync_advances_clean_clone;
          Alcotest.test_case "suppresses post-merge hook" `Quick
            test_sync_fast_forward_suppresses_post_merge_hook;
          Alcotest.test_case "already current" `Quick test_sync_already_current;
          Alcotest.test_case "preserves dirty tree" `Quick test_sync_preserves_dirty_tree;
          Alcotest.test_case "refuses diverged clone" `Quick test_sync_refuses_diverged_clone;
          Alcotest.test_case "skips non-default branch" `Quick test_sync_skips_non_default_branch;
        ] );
      ( "change_notification",
        [
          Alcotest.test_case "configuration change wakes scheduler" `Quick
            test_repo_sync_change_notification_wakes_waiter;
        ] );
    ]
