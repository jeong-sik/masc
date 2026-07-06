(** Tests for Repo_sync module *)

open Repo_manager_types

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

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

let run_git_quiet args =
  let devnull = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close devnull)
    (fun () ->
      let argv = Array.of_list ("git" :: args) in
      try
        let pid = Unix.create_process "git" argv Unix.stdin devnull devnull in
        match Unix.waitpid [] pid with
        | _, Unix.WEXITED code -> code
        | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> 1
      with
      | Unix.Unix_error _ -> 1)

let git_available () = run_git_quiet [ "--version" ] = 0

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

let test_sync_all_reports_due_repo_failures () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let repo_dir = Filename.concat base_path "repo-fetch-fails" in
        Unix.mkdir repo_dir 0o755;
        ignore (run_git_quiet [ "init"; repo_dir ]);
        ignore
          (run_git_quiet
             [ "-C"
             ; repo_dir
             ; "remote"
             ; "add"
             ; "origin"
             ; Filename.concat base_path "missing-remote"
             ]);
        let repo =
          { (sample_repo ~sync_interval:0 ~updated_at:Int64.zero "fetch-fails") with
            local_path = repo_dir
          }
        in
        match Repo_store.save_all ~base_path [ repo ] with
        | Error e -> Alcotest.fail ("save failed: " ^ e)
        | Ok () -> (
            match Repo_sync.sync_all ~base_path ~now:(Int64.of_int 1) with
            | Ok synced ->
                Alcotest.failf
                  "sync_all must report due repo failure, got %d successes"
                  (List.length synced)
            | Error msg ->
                Alcotest.(check bool) "mentions repo id" true
                  (contains_substring msg "fetch-fails");
                match Repo_store.find ~base_path "fetch-fails" with
                | Error e -> Alcotest.fail ("find after sync failed: " ^ e)
                | Ok persisted -> (
                    match persisted.status with
                    | Error detail ->
                        Alcotest.(check bool) "persists failure detail" true
                          (String.length detail > 0)
                    | Active | Paused | Cloning ->
                        Alcotest.fail "failed repo status must be persisted as Error")))

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
        ] );
      ( "sync_all",
        [
          Alcotest.test_case "empty repos" `Quick test_sync_all_empty_repos;
          Alcotest.test_case "no due repos" `Quick test_sync_all_no_due_repos;
          Alcotest.test_case "due repo failures return Error" `Quick
            test_sync_all_reports_due_repo_failures;
        ] );
    ]
