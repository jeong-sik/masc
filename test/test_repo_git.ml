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

let contains_substring s sub =
  let sub_len = String.length sub in
  sub_len = 0
  ||
  let s_len = String.length s in
  let rec aux i =
    if i + sub_len > s_len then false
    else if String.sub s i sub_len = sub then true
    else aux (i + 1)
  in
  aux 0

let sample_repo ~url local_path =
  {
    id = "test-repo";
    name = "test-repo";
    url;
    local_path;
    default_branch = "main";
    credential_id = "default";
    keepers = [];
    status = Active;
    auto_sync = false;
    sync_interval = 0;
    created_at = Int64.zero;
    updated_at = Int64.zero;
  }

let sample_credential () =
  {
    id = "default";
    cred_type = Local;
    username = "test";
    gh_config_dir = None;
    ssh_key_path = None;
    gpg_key_id = None;
    state = Unmaterialized;
    token_sha256_prefix = None;
  }

let test_clone_ok () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let dest = Filename.concat tmp "dest" in
      let repo = sample_repo ~url:source dest in
      let cred = sample_credential () in
      match Repo_git.clone ~repository:repo ~credential:cred with
      | Ok () ->
          Alcotest.(check bool) "dest exists" true (Sys.file_exists dest);
          Alcotest.(check bool) "dest/.git exists" true
            (Sys.file_exists (Filename.concat dest ".git"))
      | Error e -> Alcotest.fail ("clone failed: " ^ e))

let test_clone_bad_url () =
  with_temp_dir (fun tmp ->
      let dest = Filename.concat tmp "dest" in
      let repo = sample_repo ~url:"/nonexistent/path/to/repo" dest in
      let cred = sample_credential () in
      match Repo_git.clone ~repository:repo ~credential:cred with
      | Ok () -> Alcotest.fail "expected clone to fail"
      | Error _ -> ())

let test_get_branches () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let dest = Filename.concat tmp "dest" in
      let repo = sample_repo ~url:source dest in
      let cred = sample_credential () in
      match Repo_git.clone ~repository:repo ~credential:cred with
      | Error e -> Alcotest.fail ("clone failed: " ^ e)
      | Ok () -> (
          match Repo_git.get_branches ~repository:repo with
          | Error e -> Alcotest.fail ("get_branches failed: " ^ e)
          | Ok branches ->
              Alcotest.(check bool) "has main" true (List.mem "main" branches)))

let test_fetch () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let dest = Filename.concat tmp "dest" in
      let repo = sample_repo ~url:source dest in
      let cred = sample_credential () in
      match Repo_git.clone ~repository:repo ~credential:cred with
      | Error e -> Alcotest.fail ("clone failed: " ^ e)
      | Ok () -> (
          match Repo_git.fetch ~repository:repo ~credential:cred with
          | Error e -> Alcotest.fail ("fetch failed: " ^ e)
          | Ok remotes ->
              Alcotest.(check bool) "has origin/main" true
                (List.mem "origin/main" remotes)))

let test_checkout_worktree () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let dest = Filename.concat tmp "dest" in
      let repo = sample_repo ~url:source dest in
      let cred = sample_credential () in
      match Repo_git.clone ~repository:repo ~credential:cred with
      | Error e -> Alcotest.fail ("clone failed: " ^ e)
      | Ok () -> (
          match Repo_git.checkout_worktree ~repository:repo ~branch:"develop" with
          | Error e -> Alcotest.fail ("checkout_worktree failed: " ^ e)
          | Ok path ->
              Alcotest.(check bool) "worktree exists" true (Sys.file_exists path)))

let test_get_recent_commits () =
  with_temp_dir (fun tmp ->
      let source = Filename.concat tmp "source" in
      init_local_repo source;
      let dest = Filename.concat tmp "dest" in
      let repo = sample_repo ~url:source dest in
      let cred = sample_credential () in
      match Repo_git.clone ~repository:repo ~credential:cred with
      | Error e -> Alcotest.fail ("clone failed: " ^ e)
      | Ok () -> (
          match Repo_git.get_recent_commits ~repository:repo ~branch:"main" ~limit:5 with
          | Error e -> Alcotest.fail ("get_recent_commits failed: " ^ e)
          | Ok commits ->
              Alcotest.(check bool) "at least 1 commit" true
                (List.length commits >= 1);
              Alcotest.(check bool) "contains initial" true
                (List.exists (fun s -> contains_substring s "initial") commits)))

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
      ( "fetch", [ Alcotest.test_case "returns remotes" `Quick test_fetch ] );
      ( "checkout_worktree",
        [ Alcotest.test_case "creates worktree" `Quick test_checkout_worktree ] );
      ( "get_recent_commits",
        [ Alcotest.test_case "returns commits" `Quick test_get_recent_commits ] );
    ]
