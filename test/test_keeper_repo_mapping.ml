(** Tests for Keeper_repo_mapping module *)

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

let with_temp_base_path f =
  let dir = Filename.temp_file "mapping_test" "" in
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

let with_empty_temp_base_path f =
  let dir = Filename.temp_file "mapping_test_empty" "" in
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

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
  else begin
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755
  end

let write_mapping ?credential_id base_path keeper_id repo_ids =
  let path = Filename.concat base_path ".masc/config/keeper_repo_mappings.toml" in
  let entries =
    String.concat ", " (List.map (fun s -> "\"" ^ s ^ "\"") repo_ids)
  in
  let credential_line =
    match credential_id with
    | Some id -> Printf.sprintf "credential_id = \"%s\"\n" id
    | None -> ""
  in
  let content =
    Printf.sprintf "[mapping.%s]\nrepositories = [%s]\n%s" keeper_id entries
      credential_line
  in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

let write_repositories base_path repos =
  let path = Filename.concat base_path ".masc/config/repositories.toml" in
  let repo_block (r : repository) =
    let local_path_str =
      if Filename.is_relative r.local_path then
        Filename.concat base_path r.local_path
      else
        r.local_path
    in
    Printf.sprintf
      "[repository.%s]\nname = \"%s\"\nurl = \"%s\"\nlocal_path = \"%s\"\n\
       default_branch = \"%s\"\ncredential_id = \"%s\"\nkeepers = [%s]\n\
       status = \"%s\"\nauto_sync = %s\nsync_interval = %s\n"
      r.id
      r.name
      r.url
      local_path_str
      r.default_branch
      r.credential_id
      (String.concat ", " (List.map (fun s -> "\"" ^ s ^ "\"") r.keepers))
      (match r.status with Active -> "Active" | Paused -> "Paused" | Cloning -> "Cloning" | Error _ -> "Error")
      (string_of_bool r.auto_sync)
      (string_of_int r.sync_interval)
  in
  let content = String.concat "\n" (List.map repo_block repos) in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

let repo_under_base base_path id =
  let local_path = Filename.concat base_path ("repo-" ^ id) in
  Unix.mkdir local_path 0o755;
  local_path

let sample_repo id =
  {
    id;
    name = "repo-" ^ id;
    url = "https://github.com/test/" ^ id;
    local_path = "repos/" ^ id;
    default_branch = "main";
    credential_id = "cred-1";
    keepers = [];
    status = Active;
    auto_sync = false;
    sync_interval = 0;
    created_at = Int64.zero;
    updated_at = Int64.zero;
  }

let sample_repo_at base_path id =
  let local_path = repo_under_base base_path id in
  { (sample_repo id) with local_path }

let test_is_allowed_explicit () =
  with_temp_base_path (fun base_path ->
      write_mapping base_path "keeper-1" [ "repo-a"; "repo-b" ];
      Alcotest.(check bool)
        "allowed repo-a" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-1" ~repository_id:"repo-a" ~base_path);
      Alcotest.(check bool)
        "allowed repo-b" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-1" ~repository_id:"repo-b" ~base_path);
      Alcotest.(check bool)
        "not allowed repo-c" false
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-1" ~repository_id:"repo-c" ~base_path))

let test_is_allowed_wildcard () =
  with_temp_base_path (fun base_path ->
      write_mapping base_path "keeper-wild" [ "*" ];
      Alcotest.(check bool)
        "wildcard allows any" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-wild" ~repository_id:"any-repo" ~base_path);
      Alcotest.(check bool)
        "wildcard allows another" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-wild" ~repository_id:"another" ~base_path))

let test_is_allowed_no_mapping () =
  with_temp_base_path (fun base_path ->
      Alcotest.(check bool)
        "no mapping preserves legacy access" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"unknown" ~repository_id:"repo-a" ~base_path))

let test_validate_access_allowed () =
  with_temp_base_path (fun base_path ->
      write_mapping base_path "keeper-1" [ "repo-a" ];
      match
        Keeper_repo_mapping.validate_access ~keeper_id:"keeper-1" ~repository_id:"repo-a" ~base_path
      with
      | Ok () -> ()
      | Error e -> Alcotest.fail ("expected Ok, got: " ^ e))

let test_validate_access_denied () =
  with_temp_base_path (fun base_path ->
      write_mapping base_path "keeper-1" [ "repo-a" ];
      match
        Keeper_repo_mapping.validate_access ~keeper_id:"keeper-1" ~repository_id:"repo-b" ~base_path
      with
      | Ok _ -> Alcotest.fail "expected Error"
      | Error msg ->
          Alcotest.(check bool) "mentions not allowed" true (contains_substring msg "not allowed"))

let test_validate_path_access_allowed () =
  with_temp_base_path (fun base_path ->
      let repo_a = sample_repo_at base_path "repo-a" in
      write_repositories base_path [ repo_a ];
      write_mapping base_path "keeper-1" [ "repo-a" ];
      let path = repo_a.local_path in
      match Keeper_repo_mapping.validate_path_access ~keeper_id:"keeper-1" ~base_path ~path with
      | Ok () -> ()
      | Error e -> Alcotest.fail ("expected Ok, got: " ^ e))

let test_validate_path_access_denied () =
  with_temp_base_path (fun base_path ->
      let repo_a = sample_repo_at base_path "repo-a" in
      let repo_b = sample_repo_at base_path "repo-b" in
      write_repositories base_path [ repo_a; repo_b ];
      write_mapping base_path "keeper-1" [ "repo-a" ];
      let path = repo_b.local_path in
      match Keeper_repo_mapping.validate_path_access ~keeper_id:"keeper-1" ~base_path ~path with
      | Ok _ -> Alcotest.fail "expected Error"
      | Error msg ->
          Alcotest.(check bool) "mentions not allowed" true (contains_substring msg "not allowed"))

let test_validate_path_access_no_repo () =
  with_temp_base_path (fun base_path ->
      let repo_a = sample_repo_at base_path "repo-a" in
      write_repositories base_path [ repo_a ];
      write_mapping base_path "keeper-1" [ "repo-a" ];
      let path = Filename.concat base_path "some-unrelated-path" in
      Unix.mkdir path 0o755;
      match Keeper_repo_mapping.validate_path_access ~keeper_id:"keeper-1" ~base_path ~path with
      | Ok () -> ()
      | Error e -> Alcotest.fail ("expected Ok for no-repo path, got: " ^ e))

let test_validate_path_access_playground_repos_root_ignores_base_repo () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_path =
        Filename.concat base_path "workspace/yousleepwhen/masc-mcp"
      in
      ensure_dir masc_path;
      let masc_repo =
        { (sample_repo "masc-mcp") with
          name = "masc-mcp";
          local_path = masc_path;
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "nick0cave" [ "masc-mcp" ];
      let path =
        Filename.concat base_path ".masc/playground/docker/nick0cave/repos"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"nick0cave"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error e ->
          Alcotest.fail
            ("expected playground repos root to bypass base repo mapping, got: "
             ^ e))

let test_validate_path_access_playground_repo_uses_registered_name () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_path =
        Filename.concat base_path "workspace/yousleepwhen/masc-mcp"
      in
      ensure_dir masc_path;
      let masc_repo =
        { (sample_repo "repo-masc") with
          name = "masc-mcp";
          local_path = masc_path;
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "nick0cave" [ "repo-masc" ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/nick0cave/repos/masc-mcp/lib"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"nick0cave"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error e ->
          Alcotest.fail
            ("expected playground repo path to resolve by registered name, got: "
             ^ e))

let test_validate_path_access_playground_repo_uses_url_basename () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_path =
        Filename.concat base_path "workspace/yousleepwhen/masc-mcp"
      in
      ensure_dir masc_path;
      let masc_repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "https://github.com/jeong-sik/masc-mcp.git";
          local_path = Filename.concat base_path ".masc/repos/masc";
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "executor" [ "masc" ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/executor/repos/masc-mcp/lib"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"executor"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error e ->
          Alcotest.fail
            ("expected playground repo path to resolve by repository URL basename, got: "
             ^ e))

let test_validate_path_access_playground_unknown_repo_denied () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_path =
        Filename.concat base_path "workspace/yousleepwhen/masc-mcp"
      in
      ensure_dir masc_path;
      let masc_repo =
        { (sample_repo "masc-mcp") with
          name = "masc-mcp";
          local_path = masc_path;
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "nick0cave" [ "masc-mcp" ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/nick0cave/repos/unknown/lib"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"nick0cave"
          ~base_path ~path
      with
      | Ok () -> Alcotest.fail "expected unknown playground repo to be denied"
      | Error msg ->
          Alcotest.(check bool)
            "mentions not allowed" true (contains_substring msg "not allowed"))

let test_apply_mapping_explicit () =
  with_temp_base_path (fun base_path ->
      write_mapping base_path "keeper-1" [ "repo-a"; "repo-c" ];
      let repos = [ sample_repo "repo-a"; sample_repo "repo-b"; sample_repo "repo-c" ] in
      let filtered =
        Keeper_repo_mapping.apply_mapping ~keeper_id:"keeper-1" ~base_path ~repositories:repos
      in
      Alcotest.(check int) "filtered count" 2 (List.length filtered);
      let ids = List.map (fun (r : repository) -> r.id) filtered in
      Alcotest.(check bool) "has repo-a" true (List.mem "repo-a" ids);
      Alcotest.(check bool) "has repo-c" true (List.mem "repo-c" ids);
      Alcotest.(check bool) "no repo-b" false (List.mem "repo-b" ids))

let test_apply_mapping_wildcard () =
  with_temp_base_path (fun base_path ->
      write_mapping base_path "keeper-wild" [ "*" ];
      let repos = [ sample_repo "repo-a"; sample_repo "repo-b" ] in
      let filtered =
        Keeper_repo_mapping.apply_mapping ~keeper_id:"keeper-wild" ~base_path ~repositories:repos
      in
      Alcotest.(check int) "wildcard returns all" 2 (List.length filtered))

let test_apply_mapping_no_mapping () =
  with_temp_base_path (fun base_path ->
      let repos = [ sample_repo "repo-a"; sample_repo "repo-b" ] in
      let filtered =
        Keeper_repo_mapping.apply_mapping ~keeper_id:"unknown" ~base_path ~repositories:repos
      in
      Alcotest.(check int) "no mapping returns all for compatibility" 2 (List.length filtered))

let test_allowed_repositories () =
  with_temp_base_path (fun base_path ->
      write_mapping base_path "keeper-1" [ "repo-x"; "repo-y" ];
      match Keeper_repo_mapping.allowed_repositories ~keeper_id:"keeper-1" ~base_path with
      | Error e -> Alcotest.fail ("unexpected error: " ^ e)
      | Ok ids ->
          Alcotest.(check int) "count" 2 (List.length ids);
          Alcotest.(check bool) "has repo-x" true (List.mem "repo-x" ids);
          Alcotest.(check bool) "has repo-y" true (List.mem "repo-y" ids))

let test_allowed_repositories_no_mapping () =
  with_temp_base_path (fun base_path ->
      match Keeper_repo_mapping.allowed_repositories ~keeper_id:"unknown" ~base_path with
      | Ok _ -> Alcotest.fail "expected Error"
      | Error msg ->
          Alcotest.(check bool) "mentions no mapping" true (contains_substring msg "No mapping"))

let test_save_mapping_creates_config_dir () =
  with_empty_temp_base_path (fun base_path ->
      let mapping =
        {
          keeper_id = "keeper-new";
          repository_ids = [ "repo-a"; "repo-b" ];
          github_credential_id = None;
        }
      in
      match Keeper_repo_mapping.save_mapping ~base_path mapping with
      | Error e -> Alcotest.fail ("save_mapping failed: " ^ e)
      | Ok () -> (
          match Keeper_repo_mapping.allowed_repositories ~keeper_id:"keeper-new" ~base_path with
          | Error e -> Alcotest.fail ("allowed_repositories failed: " ^ e)
          | Ok ids ->
              Alcotest.(check int) "saved count" 2 (List.length ids);
              Alcotest.(check bool) "has repo-a" true (List.mem "repo-a" ids)))

let test_save_mapping_preserves_credential_id () =
  with_empty_temp_base_path (fun base_path ->
      let mapping =
        {
          keeper_id = "keeper-new";
          repository_ids = ["*"];
          github_credential_id = Some "cred-selected";
        }
      in
      match Keeper_repo_mapping.save_mapping ~base_path mapping with
      | Error e -> Alcotest.fail ("save_mapping failed: " ^ e)
      | Ok () -> (
          match Keeper_repo_mapping.load_all ~base_path with
          | Error e -> Alcotest.fail ("load_all failed: " ^ e)
          | Ok [loaded] ->
              Alcotest.(check (option string))
                "credential id"
                (Some "cred-selected")
                loaded.github_credential_id
          | Ok rows ->
              Alcotest.failf "expected one mapping, got %d" (List.length rows)))

let test_load_all_trims_credential_id () =
  with_temp_base_path (fun base_path ->
      write_mapping ~credential_id:" cred-selected " base_path "keeper-1" [ "*" ];
      match Keeper_repo_mapping.load_all ~base_path with
      | Error e -> Alcotest.fail ("load_all failed: " ^ e)
      | Ok [loaded] ->
          Alcotest.(check (option string))
            "trimmed credential id"
            (Some "cred-selected")
            loaded.github_credential_id
      | Ok rows -> Alcotest.failf "expected one mapping, got %d" (List.length rows))

let test_load_all_rejects_non_string_credential_id () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/keeper_repo_mappings.toml" in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          output_string oc
            "[mapping.keeper-1]\nrepositories = [\"*\"]\ncredential_id = 42\n");
      match Keeper_repo_mapping.load_all ~base_path with
      | Ok _ -> Alcotest.fail "expected non-string credential_id to fail"
      | Error msg ->
          Alcotest.(check bool)
            "mentions credential_id"
            true
            (contains_substring msg "credential_id"))

let sample_credential id cred_type =
  {
    id;
    cred_type;
    username = "user-" ^ id;
    gh_config_dir = None;
    ssh_key_path = None;
    gpg_key_id = None;
    state = Unmaterialized;
    token_sha256_prefix = None;
  }

let test_credentials_for_keeper_explicit () =
  with_temp_base_path (fun base_path ->
      let cred1 = sample_credential "cred-1" Github in
      let cred2 = sample_credential "cred-2" Gitlab in
      let repo_a =
        { (sample_repo "repo-a") with local_path = repo_under_base base_path "repo-a"; credential_id = "cred-1" }
      in
      let repo_b =
        { (sample_repo "repo-b") with local_path = repo_under_base base_path "repo-b"; credential_id = "cred-2" }
      in
      write_repositories base_path [ repo_a; repo_b ];
      (match Credential_store.add ~base_path cred1 with
       | Error e -> Alcotest.fail ("add cred1 failed: " ^ e)
       | Ok _ -> (
           match Credential_store.add ~base_path cred2 with
           | Error e -> Alcotest.fail ("add cred2 failed: " ^ e)
           | Ok _ -> (
               write_mapping base_path "keeper-1" [ "repo-a" ];
               match Keeper_repo_mapping.credentials_for_keeper ~base_path ~keeper_id:"keeper-1" with
               | Error e -> Alcotest.fail ("credentials_for_keeper failed: " ^ e)
               | Ok creds ->
                   Alcotest.(check int) "count" 1 (List.length creds);
                   Alcotest.(check string) "cred id" "cred-1" (List.hd creds).id))))

let test_credentials_for_keeper_wildcard () =
  with_temp_base_path (fun base_path ->
      let cred1 = sample_credential "cred-1" Github in
      let cred2 = sample_credential "cred-2" Gitlab in
      let repo_a =
        { (sample_repo "repo-a") with local_path = repo_under_base base_path "repo-a"; credential_id = "cred-1" }
      in
      let repo_b =
        { (sample_repo "repo-b") with local_path = repo_under_base base_path "repo-b"; credential_id = "cred-2" }
      in
      write_repositories base_path [ repo_a; repo_b ];
      (match Credential_store.add ~base_path cred1 with
       | Error e -> Alcotest.fail ("add cred1 failed: " ^ e)
       | Ok _ -> (
           match Credential_store.add ~base_path cred2 with
           | Error e -> Alcotest.fail ("add cred2 failed: " ^ e)
           | Ok _ -> (
               write_mapping base_path "keeper-wild" [ "*" ];
               match Keeper_repo_mapping.credentials_for_keeper ~base_path ~keeper_id:"keeper-wild" with
               | Error e -> Alcotest.fail ("credentials_for_keeper failed: " ^ e)
               | Ok creds ->
                   Alcotest.(check int) "count" 2 (List.length creds);
                   let ids = List.map (fun (c : credential) -> c.id) creds in
                   Alcotest.(check bool) "has cred-1" true (List.mem "cred-1" ids);
                   Alcotest.(check bool) "has cred-2" true (List.mem "cred-2" ids)))))

let test_credentials_for_keeper_direct_credential_overrides_repo () =
  with_temp_base_path (fun base_path ->
      let selected = sample_credential "cred-selected" Github in
      let repo_a =
        {
          (sample_repo "repo-a") with
          local_path = repo_under_base base_path "repo-a";
          credential_id = "cred-missing-repo";
        }
      in
      write_repositories base_path [repo_a];
      (match Credential_store.add ~base_path selected with
       | Error e -> Alcotest.fail ("add selected failed: " ^ e)
       | Ok _ -> (
           write_mapping ~credential_id:"cred-selected" base_path "keeper-1" [ "repo-a" ];
           match Keeper_repo_mapping.credentials_for_keeper ~base_path ~keeper_id:"keeper-1" with
           | Error e -> Alcotest.fail ("credentials_for_keeper failed: " ^ e)
           | Ok creds ->
               Alcotest.(check int) "count" 1 (List.length creds);
               Alcotest.(check string) "cred id" "cred-selected" (List.hd creds).id)))

let test_credentials_for_keeper_direct_missing_credential () =
  with_temp_base_path (fun base_path ->
      write_mapping ~credential_id:"cred-missing" base_path "keeper-1" [ "*" ];
      match Keeper_repo_mapping.credentials_for_keeper ~base_path ~keeper_id:"keeper-1" with
      | Ok creds ->
          Alcotest.failf "expected Error for missing direct credential, got %d creds"
            (List.length creds)
      | Error msg ->
          Alcotest.(check bool)
            "mentions missing credential"
            true (contains_substring msg "cred-missing"))

let test_credentials_for_keeper_direct_wrong_type () =
  with_temp_base_path (fun base_path ->
      let local_cred = sample_credential "cred-local" Local in
      (match Credential_store.add ~base_path local_cred with
       | Error e -> Alcotest.fail ("add local credential failed: " ^ e)
       | Ok _ ->
           write_mapping ~credential_id:"cred-local" base_path "keeper-1" [ "*" ];
           match Keeper_repo_mapping.credentials_for_keeper ~base_path ~keeper_id:"keeper-1" with
           | Ok creds ->
               Alcotest.failf
                 "expected Error for non-GitHub direct credential, got %d creds"
                 (List.length creds)
           | Error msg ->
               Alcotest.(check bool)
                 "mentions credential id"
                 true
                 (contains_substring msg "cred-local");
               Alcotest.(check bool)
                 "mentions GitHub type"
                 true
                 (contains_substring msg "must be of type GitHub");
               Alcotest.(check bool)
                 "mentions actual type"
                 true
                 (contains_substring msg "Local")))

let test_credentials_for_keeper_mapping_parse_error () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/keeper_repo_mappings.toml" in
      let () =
        let oc = open_out path in
        Fun.protect
          ~finally:(fun () -> close_out_noerr oc)
          (fun () ->
            output_string oc
              "[mapping.keeper-1]\nrepositories = [\"*\"]\ncredential_id = 42\n")
      in
      match Keeper_repo_mapping.credentials_for_keeper ~base_path ~keeper_id:"keeper-1" with
      | Ok creds ->
          Alcotest.failf "expected mapping parse error, got %d creds"
            (List.length creds)
      | Error msg ->
          Alcotest.(check bool)
            "mentions credential_id"
            true
            (contains_substring msg "credential_id"))

let test_credentials_for_keeper_no_mapping () =
  with_temp_base_path (fun base_path ->
      match Keeper_repo_mapping.credentials_for_keeper ~base_path ~keeper_id:"unknown" with
      | Error e -> Alcotest.fail ("unexpected error: " ^ e)
      | Ok creds -> Alcotest.(check int) "empty for no mapping" 0 (List.length creds))

let () =
  Alcotest.run "Keeper_repo_mapping"
    [
      ( "is_allowed",
        [
          Alcotest.test_case "explicit list" `Quick test_is_allowed_explicit;
          Alcotest.test_case "wildcard" `Quick test_is_allowed_wildcard;
          Alcotest.test_case "no mapping" `Quick test_is_allowed_no_mapping;
        ] );
      ( "validate_access",
        [
          Alcotest.test_case "allowed" `Quick test_validate_access_allowed;
          Alcotest.test_case "denied" `Quick test_validate_access_denied;
        ] );
      ( "validate_path_access",
        [
          Alcotest.test_case "allowed" `Quick test_validate_path_access_allowed;
          Alcotest.test_case "denied" `Quick test_validate_path_access_denied;
          Alcotest.test_case "no repo" `Quick test_validate_path_access_no_repo;
          Alcotest.test_case "playground repos root ignores base repo" `Quick
            test_validate_path_access_playground_repos_root_ignores_base_repo;
          Alcotest.test_case "playground repo resolves registered name" `Quick
            test_validate_path_access_playground_repo_uses_registered_name;
          Alcotest.test_case "playground repo resolves repository URL basename" `Quick
            test_validate_path_access_playground_repo_uses_url_basename;
          Alcotest.test_case "playground unknown repo denied" `Quick
            test_validate_path_access_playground_unknown_repo_denied;
        ] );
      ( "apply_mapping",
        [
          Alcotest.test_case "explicit list" `Quick test_apply_mapping_explicit;
          Alcotest.test_case "wildcard" `Quick test_apply_mapping_wildcard;
          Alcotest.test_case "no mapping" `Quick test_apply_mapping_no_mapping;
        ] );
      ( "allowed_repositories",
        [
          Alcotest.test_case "returns list" `Quick test_allowed_repositories;
          Alcotest.test_case "no mapping" `Quick test_allowed_repositories_no_mapping;
        ] );
      ( "save_mapping",
        [
          Alcotest.test_case "creates config dir" `Quick test_save_mapping_creates_config_dir;
          Alcotest.test_case "preserves credential id" `Quick test_save_mapping_preserves_credential_id;
          Alcotest.test_case "loads trimmed credential id" `Quick test_load_all_trims_credential_id;
          Alcotest.test_case "rejects non-string credential id" `Quick
            test_load_all_rejects_non_string_credential_id;
        ] );
      ( "credentials_for_keeper",
        [
          Alcotest.test_case "explicit mapping" `Quick test_credentials_for_keeper_explicit;
          Alcotest.test_case "wildcard mapping" `Quick test_credentials_for_keeper_wildcard;
          Alcotest.test_case "direct credential overrides repo" `Quick test_credentials_for_keeper_direct_credential_overrides_repo;
          Alcotest.test_case "direct credential missing" `Quick test_credentials_for_keeper_direct_missing_credential;
          Alcotest.test_case "direct credential wrong type" `Quick test_credentials_for_keeper_direct_wrong_type;
          Alcotest.test_case "mapping parse error" `Quick
            test_credentials_for_keeper_mapping_parse_error;
          Alcotest.test_case "no mapping" `Quick test_credentials_for_keeper_no_mapping;
        ] );
    ]
