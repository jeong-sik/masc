(** E2E tests for repository lifecycle: register -> clone -> list branches.

    Validates the Week 7 integration checklist:
    - 저장소 등록 → clone → 브랜치 표시
*)

open Repo_manager_types

let with_temp_dir f =
  let dir = Filename.temp_file "repo_e2e_test" "" in
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

let with_temp_base_path f =
  let dir = Filename.temp_file "repo_e2e_test" "" in
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
    match run_cmd ~cwd:path ["git"; "config"; "user.email"; "test@example.com"] with
    | Ok () -> ()
    | Error e -> failwith e
  in
  let () =
    match run_cmd ~cwd:path ["git"; "config"; "user.name"; "Test User"] with
    | Ok () -> ()
    | Error e -> failwith e
  in
  let () =
    match run_cmd ~cwd:path ["git"; "commit"; "--allow-empty"; "-m"; "initial"] with
    | Ok () -> ()
    | Error e -> failwith ("git commit failed: " ^ e)
  in
  let () =
    match run_cmd ~cwd:path ["git"; "branch"; "develop"] with
    | Ok () -> ()
    | Error e -> failwith ("git branch develop failed: " ^ e)
  in
  let () =
    match run_cmd ~cwd:path ["git"; "branch"; "feature/test"] with
    | Ok () -> ()
    | Error e -> failwith ("git branch feature/test failed: " ^ e)
  in
  ()

let sample_repo ~id ~url local_path =
  {
    id;
    name = id;
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

let test_register_and_clone () =
  with_temp_base_path (fun base_path ->
      with_temp_dir (fun git_tmp ->
          let source = Filename.concat git_tmp "source" in
          init_local_repo source;
          let dest = Filename.concat git_tmp "dest" in
          let repo = sample_repo ~id:"e2e-repo" ~url:source dest in
          match Repo_store.add ~base_path repo with
          | Error e -> Alcotest.fail ("add failed: " ^ e)
          | Ok added ->
              Alcotest.(check string) "id preserved" "e2e-repo" added.id;
              let cred = sample_credential () in
              match Repo_git.clone ~repository:added ~credential:cred with
              | Ok () ->
                  Alcotest.(check bool) "cloned dest exists" true (Sys.file_exists dest);
                  Alcotest.(check bool) "cloned .git exists" true
                    (Sys.file_exists (Filename.concat dest ".git"))
              | Error e -> Alcotest.fail ("clone failed: " ^ e)))

let test_register_clone_and_list_branches () =
  with_temp_base_path (fun base_path ->
      with_temp_dir (fun git_tmp ->
          let source = Filename.concat git_tmp "source" in
          init_local_repo source;
          let dest = Filename.concat git_tmp "dest" in
          let repo = sample_repo ~id:"e2e-repo-branches" ~url:source dest in
          match Repo_store.add ~base_path repo with
          | Error e -> Alcotest.fail ("add failed: " ^ e)
          | Ok added ->
              let cred = sample_credential () in
              (match Repo_git.clone ~repository:added ~credential:cred with
               | Error e -> Alcotest.fail ("clone failed: " ^ e)
               | Ok () ->
                   match Repo_store.list_branches ~base_path added.id with
                   | Error e -> Alcotest.fail ("list_branches failed: " ^ e)
                   | Ok branches ->
                       Alcotest.(check bool) "has main" true (List.mem "main" branches);
                       Alcotest.(check bool) "has develop" true (List.mem "develop" branches);
                       Alcotest.(check bool) "has feature/test" true (List.mem "feature/test" branches)
              )))

let test_e2e_full_lifecycle () =
  with_temp_base_path (fun base_path ->
      with_temp_dir (fun git_tmp ->
          let source = Filename.concat git_tmp "source" in
          init_local_repo source;
          let dest = Filename.concat git_tmp "dest" in
          let repo = sample_repo ~id:"lifecycle-repo" ~url:source dest in
          (* 1. Add *)
          let added =
            match Repo_store.add ~base_path repo with
            | Error e -> Alcotest.fail ("add failed: " ^ e)
            | Ok r -> r
          in
          (* 2. Find *)
          (match Repo_store.find ~base_path added.id with
           | Error e -> Alcotest.fail ("find failed: " ^ e)
           | Ok found ->
               Alcotest.(check string) "found url" source found.url);
          (* 3. Clone *)
          let cred = sample_credential () in
          (match Repo_git.clone ~repository:added ~credential:cred with
           | Error e -> Alcotest.fail ("clone failed: " ^ e)
           | Ok () -> ());
          (* 4. List branches *)
          (match Repo_store.list_branches ~base_path added.id with
           | Error e -> Alcotest.fail ("list_branches failed: " ^ e)
           | Ok branches ->
               Alcotest.(check bool) "has branches" true (List.length branches > 0));
          (* 5. Update status *)
          let updated = { added with status = Paused } in
          (match Repo_store.update ~base_path added.id updated with
           | Error e -> Alcotest.fail ("update failed: " ^ e)
           | Ok persisted ->
               Alcotest.(check bool) "status paused" true
                 (persisted.status = Paused));
          (* 6. Remove *)
          (match Repo_store.remove ~base_path added.id with
           | Error e -> Alcotest.fail ("remove failed: " ^ e)
           | Ok () ->
               match Repo_store.find ~base_path added.id with
               | Ok _ -> Alcotest.fail "expected not found after remove"
               | Error _ -> ())))

let () =
  Alcotest.run "Repository E2E"
    [
      ( "lifecycle",
        [
          Alcotest.test_case "register and clone" `Quick test_register_and_clone;
          Alcotest.test_case "register, clone, and list branches" `Quick
            test_register_clone_and_list_branches;
          Alcotest.test_case "full lifecycle" `Quick test_e2e_full_lifecycle;
        ] );
    ]
