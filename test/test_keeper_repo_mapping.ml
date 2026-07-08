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

let is_directory_no_follow path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> true
  | _ -> false
  | exception Unix.Unix_error _ -> false

let path_exists_no_follow path =
  match Unix.lstat path with
  | _ -> true
  | exception Unix.Unix_error _ -> false

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
        if path_exists_no_follow path then
          if is_directory_no_follow path then begin
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
        if path_exists_no_follow path then
          if is_directory_no_follow path then begin
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

let write_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let write_mapping_raw base_path content =
  write_file (Keeper_repo_mapping.mappings_toml_path base_path) content

let write_mapping base_path keeper_id repo_ids =
  let mapping =
    Repo_manager_types.make_keeper_repo_mapping ~keeper_id
      ~repository_ids:repo_ids
  in
  match Keeper_repo_mapping.save_mapping ~base_path mapping with
  | Ok () -> ()
  | Error e -> Alcotest.fail ("write_mapping failed: " ^ e)

let write_repositories base_path repos =
  let path = Filename.concat base_path ".masc/config/repositories.toml" in
  let quoted_list values =
    String.concat ", " (List.map (fun s -> "\"" ^ s ^ "\"") values)
  in
  let repo_block (r : repository) =
    let local_path_str =
      if Filename.is_relative r.local_path then
        Filename.concat base_path r.local_path
      else
        r.local_path
    in
    Printf.sprintf
      "[repository.%s]\nname = \"%s\"\nurl = \"%s\"\nlocal_path = \"%s\"\n\
       default_branch = \"%s\"\naliases = [%s]\nkeepers = [%s]\n\
       status = \"%s\"\nauto_sync = %s\nsync_interval = %s\n"
      r.id
      r.name
      r.url
      local_path_str
      r.default_branch
      (quoted_list r.aliases)
      (quoted_list r.keepers)
      (match r.status with Active -> "Active" | Paused -> "Paused" | Cloning -> "Cloning" | Error _ -> "Error")
      (string_of_bool r.auto_sync)
      (string_of_int r.sync_interval)
  in
  let content = String.concat "\n" (List.map repo_block repos) in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

let write_git_origin repo_root url =
  let git_dir = Filename.concat repo_root ".git" in
  ensure_dir git_dir;
  let config_path = Filename.concat git_dir "config" in
  let content =
    Printf.sprintf "[remote \"origin\"]\n\turl = %s\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n" url
  in
  write_file config_path content

let write_git_remotes repo_root remotes =
  let git_dir = Filename.concat repo_root ".git" in
  ensure_dir git_dir;
  let config_path = Filename.concat git_dir "config" in
  let remote_block (name, url) =
    Printf.sprintf
      "[remote \"%s\"]\n\turl = %s\n\tfetch = +refs/heads/*:refs/remotes/%s/*\n"
      name url name
  in
  write_file config_path (String.concat "" (List.map remote_block remotes))

let write_gitdir_origin repo_root ~gitdir_ref ~gitdir_path ~url =
  write_file (Filename.concat repo_root ".git")
    (Printf.sprintf "gitdir: %s\n" gitdir_ref);
  write_file (Filename.concat gitdir_path "config")
    (Printf.sprintf
       "[remote \"origin\"]\n\turl = %s\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
       url)

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
    aliases = [];
    default_branch = "main";
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
      write_repositories base_path
        [ sample_repo "repo-a"; sample_repo "repo-b"; sample_repo "repo-c" ];
      write_mapping base_path "keeper-1" [ "repo-a"; "repo-b" ];
      Alcotest.(check bool)
        "allowed repo-a" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-1" ~repository_id:"repo-a" ~base_path);
      Alcotest.(check bool)
        "allowed repo-b" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-1" ~repository_id:"repo-b" ~base_path);
      Alcotest.(check bool)
        "explicit mapping does not cap registered repo-c" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-1" ~repository_id:"repo-c" ~base_path))

let test_is_allowed_wildcard () =
  with_temp_base_path (fun base_path ->
      write_repositories base_path [ sample_repo "any-repo"; sample_repo "another" ];
      write_mapping base_path "keeper-wild" [ "*" ];
      Alcotest.(check bool)
        "wildcard allows registered repo" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-wild" ~repository_id:"any-repo" ~base_path);
      Alcotest.(check bool)
        "wildcard allows another registered repo" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-wild" ~repository_id:"another" ~base_path);
      Alcotest.(check bool)
        "wildcard denies unregistered repo id" false
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-wild" ~repository_id:"not-registered" ~base_path))

let test_is_allowed_no_mapping () =
  with_temp_base_path (fun base_path ->
      write_repositories base_path [ sample_repo "repo-a" ];
      Alcotest.(check bool)
        "no mapping defaults to registered repositories" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"unknown" ~repository_id:"repo-a" ~base_path);
      Alcotest.(check bool)
        "no mapping denies unregistered repositories" false
        (Keeper_repo_mapping.is_allowed ~keeper_id:"unknown" ~repository_id:"repo-b" ~base_path))

let test_is_allowed_mapping_parse_error () =
  with_temp_base_path (fun base_path ->
      write_repositories base_path [ sample_repo "repo-a" ];
      write_mapping_raw base_path
        "[mapping.keeper-1]\nrepositories = 42\n";
      Alcotest.(check bool)
        "mapping parse error does not cap registered repository access" true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-1" ~repository_id:"repo-a" ~base_path))

let test_load_all_rejects_non_table_mapping () =
  with_temp_base_path (fun base_path ->
      write_mapping_raw base_path "mapping = 42\n";
      match Keeper_repo_mapping.load_all ~base_path with
      | Ok _ -> Alcotest.fail "expected malformed top-level mapping to fail"
      | Error msg ->
          Alcotest.(check bool)
            "mentions mapping table"
            true
            (contains_substring msg "mapping field must be a table"))

let test_load_all_parses_wildcard_scope () =
  with_temp_base_path (fun base_path ->
      write_mapping_raw base_path
        "[mapping.keeper-wild]\nrepositories = [\"*\"]\n";
      match Keeper_repo_mapping.load_all ~base_path with
      | Error msg -> Alcotest.fail ("load_all failed: " ^ msg)
      | Ok [ mapping ] -> (
          match Keeper_repo_mapping.repository_scope_of_mapping mapping with
          | All_repositories -> ()
          | Selected_repositories ids ->
              Alcotest.fail
                (Printf.sprintf
                   "expected wildcard scope, got selected repositories: %s"
                   (String.concat "," ids)))
      | Ok mappings ->
          Alcotest.fail
            (Printf.sprintf "expected one mapping, got %d" (List.length mappings)))

let test_is_allowed_ignores_external_mapping_revocation () =
  with_temp_base_path (fun base_path ->
      write_repositories base_path
        [ sample_repo "repo-a"; sample_repo "repo-revoked-target" ];
      write_mapping base_path "keeper-1" [ "repo-a" ];
      Alcotest.(check bool)
        "initial repo allowed"
        true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-1" ~repository_id:"repo-a" ~base_path);
      write_mapping_raw base_path
        "[mapping.keeper-1]\nrepositories = [\"repo-revoked-target\"]\n";
      Alcotest.(check bool)
        "externally removed repo still allowed while registered"
        true
        (Keeper_repo_mapping.is_allowed ~keeper_id:"keeper-1" ~repository_id:"repo-a" ~base_path);
      Alcotest.(check bool)
        "new external mapping allowed"
        true
        (Keeper_repo_mapping.is_allowed
           ~keeper_id:"keeper-1"
           ~repository_id:"repo-revoked-target"
           ~base_path))

let test_validate_access_allowed () =
  with_temp_base_path (fun base_path ->
      write_repositories base_path [ sample_repo "repo-a" ];
      write_mapping base_path "keeper-1" [ "repo-a" ];
      match
        Keeper_repo_mapping.validate_access ~keeper_id:"keeper-1" ~repository_id:"repo-a" ~base_path
      with
      | Ok () -> ()
      | Error e -> Alcotest.fail ("expected Ok, got: " ^ e))

let test_validate_access_explicit_mapping_does_not_cap_registered_repo () =
  with_temp_base_path (fun base_path ->
      write_repositories base_path [ sample_repo "repo-a"; sample_repo "repo-b" ];
      write_mapping base_path "keeper-1" [ "repo-a" ];
      match
        Keeper_repo_mapping.validate_access ~keeper_id:"keeper-1" ~repository_id:"repo-b" ~base_path
      with
      | Ok () -> ()
      | Error msg ->
          Alcotest.fail
            ("expected registered repo outside advisory mapping to be allowed, got: "
             ^ msg))

let test_validate_access_no_mapping () =
  with_temp_base_path (fun base_path ->
      write_repositories base_path [ sample_repo "repo-a" ];
      match
        Keeper_repo_mapping.validate_access ~keeper_id:"unknown" ~repository_id:"repo-a" ~base_path
      with
      | Ok () -> ()
      | Error msg -> Alcotest.fail ("expected Ok for default wildcard scope, got: " ^ msg))

let test_validate_path_access_allowed () =
  with_temp_base_path (fun base_path ->
      let repo_a = sample_repo_at base_path "repo-a" in
      write_repositories base_path [ repo_a ];
      write_mapping base_path "keeper-1" [ "repo-a" ];
      let path = repo_a.local_path in
      match Keeper_repo_mapping.validate_path_access ~keeper_id:"keeper-1" ~base_path ~path with
      | Ok () -> ()
      | Error e -> Alcotest.fail ("expected Ok, got: " ^ e))

let test_validate_path_access_explicit_mapping_does_not_cap_registered_repo () =
  with_temp_base_path (fun base_path ->
      let repo_a = sample_repo_at base_path "repo-a" in
      let repo_b = sample_repo_at base_path "repo-b" in
      write_repositories base_path [ repo_a; repo_b ];
      write_mapping base_path "keeper-1" [ "repo-a" ];
      let path = repo_b.local_path in
      match Keeper_repo_mapping.validate_path_access ~keeper_id:"keeper-1" ~base_path ~path with
      | Ok () -> ()
      | Error msg ->
          Alcotest.fail
            ("expected registered repo path outside advisory mapping to be allowed, got: "
             ^ msg))

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

let test_validate_path_access_rejects_repo_store_load_error () =
  with_temp_base_path (fun base_path ->
      write_mapping base_path "keeper-1" [ "repo-a" ];
      write_file
        (Filename.concat base_path ".masc/config/repositories.toml")
        "[repository.repo-a]\nurl = 42\n";
      let path = Filename.concat base_path "repos/repo-a/file.txt" in
      ensure_dir (Filename.dirname path);
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"keeper-1"
          ~base_path ~path
      with
      | Ok () -> Alcotest.fail "expected repository store load failure to deny access"
      | Error msg ->
          Alcotest.(check bool)
            "mentions store load failure" true
            (contains_substring msg "Repository store load failed"))

let test_validate_path_access_playground_rejects_repo_store_load_error () =
  with_temp_base_path (fun base_path ->
      write_mapping base_path "executor" [ "masc" ];
      write_file
        (Filename.concat base_path ".masc/config/repositories.toml")
        "[repository.masc]\nurl = 42\n";
      let path =
        Filename.concat base_path
          ".masc/playground/docker/executor/repos/masc/lib"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"executor"
          ~base_path ~path
      with
      | Ok () -> Alcotest.fail "expected playground load failure to deny access"
      | Error msg ->
          Alcotest.(check bool)
            "mentions store load failure" true
            (contains_substring msg "Repository store load failed"))

let test_validate_path_access_playground_repos_root_ignores_base_repo () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_path =
        Filename.concat base_path "workspace/yousleepwhen/masc"
      in
      ensure_dir masc_path;
      let masc_repo =
        { (sample_repo "masc") with
          name = "masc";
          local_path = masc_path;
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "nick0cave" [ "masc" ];
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
        Filename.concat base_path "workspace/yousleepwhen/masc"
      in
      ensure_dir masc_path;
      let masc_repo =
        { (sample_repo "repo-masc") with
          name = "masc";
          local_path = masc_path;
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "nick0cave" [ "repo-masc" ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/nick0cave/repos/masc/lib"
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
        Filename.concat base_path "workspace/yousleepwhen/masc"
      in
      ensure_dir masc_path;
      let masc_repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "https://github.com/jeong-sik/masc.git";
          local_path = Filename.concat base_path ".masc/repos/masc";
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "executor" [ "masc" ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/executor/repos/masc/lib"
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

let test_validate_path_access_playground_repo_uses_explicit_alias () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "https://github.com/jeong-sik/masc.git";
          local_path = Filename.concat base_path ".masc/repos/masc";
          aliases = [ "masc-mcp" ];
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
            ("expected playground repo path to resolve by explicit repository alias, got: "
             ^ e))

let test_validate_path_access_url_basename_case_only_drift_allowed () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let repo =
        { (sample_repo "bmad-method") with
          name = "bmad-method";
          url = "https://github.com/bmad-code-org/BMAD-METHOD";
          local_path = Filename.concat base_path ".masc/repos/bmad-method";
        }
      in
      write_repositories base_path [ root_repo; repo ];
      write_mapping base_path "executor" [ "bmad-method" ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/executor/repos/bmad-method/lib"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"executor"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error e ->
          Alcotest.fail
            ("expected case-only URL basename drift to match repository identity, got: "
             ^ e))

let test_validate_path_access_rejects_repo_identity_mismatch () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let bad_repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "https://github.com/jeong-sik/masc-mcp";
          local_path = Filename.concat base_path ".masc/repos/masc";
        }
      in
      write_repositories base_path [ root_repo; bad_repo ];
      write_mapping base_path "executor" [ "masc" ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/executor/repos/masc/lib"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"executor"
          ~base_path ~path
      with
      | Ok () -> Alcotest.fail "expected repository identity mismatch"
      | Error msg ->
          Alcotest.(check bool)
            "mentions identity mismatch" true
            (contains_substring msg "Repository identity mismatch");
          Alcotest.(check bool)
            "mentions mismatched basename" true
            (contains_substring msg "masc-mcp"))

let test_validate_path_access_rejects_mismatched_url_basename_alias () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let bad_repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "https://github.com/jeong-sik/masc-mcp";
          local_path = Filename.concat base_path ".masc/repos/masc";
        }
      in
      write_repositories base_path [ root_repo; bad_repo ];
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
      | Ok () ->
          Alcotest.fail
            "expected URL basename not to authorize a mismatched repository"
      | Error msg ->
          Alcotest.(check bool)
            "mentions identity mismatch" true
            (contains_substring msg "Repository identity mismatch");
          Alcotest.(check bool)
            "mentions mismatched basename" true
            (contains_substring msg "masc-mcp"))

let test_validate_path_access_wildcard_rejects_mismatched_url_basename () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let bad_repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "https://github.com/jeong-sik/masc-mcp";
          local_path = Filename.concat base_path ".masc/repos/masc";
        }
      in
      write_repositories base_path [ root_repo; bad_repo ];
      write_mapping base_path "executor" [ "*" ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/executor/repos/masc-mcp/lib"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"executor"
          ~base_path ~path
      with
      | Ok () ->
          Alcotest.fail
            "expected wildcard mapping not to authorize mismatched URL basename"
      | Error msg ->
          Alcotest.(check bool)
            "mentions identity mismatch" true
            (contains_substring msg "Repository identity mismatch");
          Alcotest.(check bool)
            "mentions mismatched basename" true
            (contains_substring msg "masc-mcp"))

let test_validate_path_access_rejects_empty_url_basename () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let bad_repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "";
          local_path = Filename.concat base_path ".masc/repos/masc";
        }
      in
      write_repositories base_path [ root_repo; bad_repo ];
      write_mapping base_path "executor" [ "masc" ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/executor/repos/masc/lib"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"executor"
          ~base_path ~path
      with
      | Ok () -> Alcotest.fail "expected empty URL basename to be denied"
      | Error msg ->
          Alcotest.(check bool)
            "mentions identity mismatch" true
            (contains_substring msg "Repository identity mismatch"))

let test_validate_path_access_playground_allows_git_remote_only_visible_clone () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "https://github.com/jeong-sik/masc.git";
          local_path = Filename.concat base_path ".masc/repos/masc";
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "executor" [ "masc" ];
      let repo_root =
        Filename.concat base_path
          ".masc/playground/docker/executor/repos/keeper-direct-clone-proof-0506"
      in
      let path = Filename.concat repo_root "docs/proof.md" in
      ensure_dir (Filename.dirname path);
      write_git_origin repo_root "https://github.com/jeong-sik/masc.git";
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"executor"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error msg ->
          Alcotest.fail
            ("expected git remote-only visible clone to be allowed, got: " ^ msg))

let test_validate_path_access_playground_allows_exact_remote_url_visible_clone () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "https://github.com/jeong-sik/masc-mcp";
          local_path = Filename.concat base_path ".masc/repos/masc";
        }
      in
      write_repositories base_path [ root_repo; repo ];
      write_mapping base_path "executor" [ "masc" ];
      let repo_root =
        Filename.concat base_path
          ".masc/playground/docker/executor/repos/keeper-direct-clone-proof-0506"
      in
      let path = Filename.concat repo_root "docs/proof.md" in
      ensure_dir (Filename.dirname path);
      write_git_origin repo_root "https://github.com/jeong-sik/masc-mcp";
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"executor"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error msg ->
          Alcotest.fail
            ("expected exact remote URL visible clone to be allowed, got: " ^ msg))

let test_validate_path_access_playground_allows_secondary_remote_visible_clone ()
  =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "https://github.com/jeong-sik/masc.git";
          local_path = Filename.concat base_path ".masc/repos/masc";
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "executor" [ "masc" ];
      let repo_root =
        Filename.concat base_path ".masc/playground/docker/executor/repos/masc-mcp"
      in
      let path = Filename.concat repo_root "docs/proof.md" in
      ensure_dir (Filename.dirname path);
      write_git_remotes repo_root
        [
          ("origin", Filename.concat base_path "workspace/yousleepwhen/masc-mcp");
          ("github", "https://github.com/jeong-sik/masc.git");
        ];
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"executor"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error msg ->
          Alcotest.fail
            ("expected secondary remote visible clone to be allowed, got: " ^ msg))

let test_validate_path_access_playground_allows_gitdir_visible_clone () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "https://github.com/jeong-sik/masc.git";
          local_path = Filename.concat base_path ".masc/repos/masc";
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "executor" [ "masc" ];
      let repos_root =
        Filename.concat base_path ".masc/playground/docker/executor/repos"
      in
      let repo_root = Filename.concat repos_root "linked-worktree" in
      let gitdir_path = Filename.concat repos_root "linked-worktree-gitdir" in
      let path = Filename.concat repo_root "docs/proof.md" in
      ensure_dir (Filename.dirname path);
      write_gitdir_origin repo_root
        ~gitdir_ref:"../linked-worktree-gitdir"
        ~gitdir_path
        ~url:"https://github.com/jeong-sik/masc.git";
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"executor"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error msg ->
          Alcotest.fail
            ("expected gitdir visible clone to be allowed, got: " ^ msg))

let test_validate_path_access_playground_large_git_config_allowed () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_repo =
        { (sample_repo "masc") with
          name = "masc";
          url = "https://github.com/jeong-sik/masc.git";
          local_path = Filename.concat base_path ".masc/repos/masc";
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "executor" [ "masc" ];
      let repos_root =
        Filename.concat base_path ".masc/playground/docker/executor/repos"
      in
      let repo_root = Filename.concat repos_root "large-config-worktree" in
      let path = Filename.concat repo_root "docs/proof.md" in
      ensure_dir (Filename.dirname path);
      ensure_dir (Filename.concat repo_root ".git");
      write_file (Filename.concat repo_root ".git/config")
        (String.make (70 * 1024) 'x'
         ^ "\n[remote \"origin\"]\n\turl = https://github.com/jeong-sik/masc.git\n");
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"executor"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error msg ->
          Alcotest.fail
            ("expected oversized git config visible clone to be allowed, got: " ^ msg))

let test_validate_path_access_playground_unknown_repo_allowed () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_path =
        Filename.concat base_path "workspace/yousleepwhen/masc"
      in
      ensure_dir masc_path;
      let masc_repo =
        { (sample_repo "masc") with
          name = "masc";
          local_path = masc_path;
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "nick0cave" [ "masc" ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/nick0cave/repos/unknown/lib"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"nick0cave"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error msg ->
          Alcotest.fail
            ("expected unknown playground repo to be allowed, got: " ^ msg))

let test_validate_path_access_playground_unknown_repo_wildcard_allowed () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_path =
        Filename.concat base_path "workspace/yousleepwhen/masc"
      in
      ensure_dir masc_path;
      let masc_repo =
        { (sample_repo "masc") with
          name = "masc";
          local_path = masc_path;
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      write_mapping base_path "nick0cave" [ "*" ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/nick0cave/repos/unknown/lib"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"nick0cave"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error msg ->
          Alcotest.fail
            ("expected unknown playground repo under wildcard to be allowed, got: "
             ^ msg))

let test_validate_path_access_playground_unknown_repo_no_mapping_allowed () =
  with_temp_base_path (fun base_path ->
      let root_repo =
        { (sample_repo "me") with name = "me"; local_path = base_path }
      in
      let masc_path =
        Filename.concat base_path "workspace/yousleepwhen/masc"
      in
      ensure_dir masc_path;
      let masc_repo =
        { (sample_repo "masc") with
          name = "masc";
          local_path = masc_path;
        }
      in
      write_repositories base_path [ root_repo; masc_repo ];
      let path =
        Filename.concat base_path
          ".masc/playground/docker/nick0cave/repos/unknown/lib"
      in
      ensure_dir path;
      match
        Keeper_repo_mapping.validate_path_access ~keeper_id:"nick0cave"
          ~base_path ~path
      with
      | Ok () -> ()
      | Error msg ->
          Alcotest.fail
            ("expected unknown playground repo without mapping to be allowed, got: "
             ^ msg))

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
      Alcotest.(check int) "no mapping returns all" 2 (List.length filtered))

let test_apply_mapping_parse_error () =
  with_temp_base_path (fun base_path ->
      write_mapping_raw base_path
        "[mapping.keeper-1]\nrepositories = 42\n";
      let repos = [ sample_repo "repo-a"; sample_repo "repo-b" ] in
      let filtered =
        Keeper_repo_mapping.apply_mapping ~keeper_id:"keeper-1" ~base_path ~repositories:repos
      in
      Alcotest.(check int)
        "mapping parse error falls back to all repositories" 2
        (List.length filtered))

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
      | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
      | Ok ids -> Alcotest.(check (list string)) "default wildcard" ["*"] ids)

let test_save_mapping_creates_config_dir () =
  with_empty_temp_base_path (fun base_path ->
      let mapping =
        Repo_manager_types.make_keeper_repo_mapping ~keeper_id:"keeper-new"
          ~repository_ids:[ "repo-a"; "repo-b" ]
      in
      match Keeper_repo_mapping.save_mapping ~base_path mapping with
      | Error e -> Alcotest.fail ("save_mapping failed: " ^ e)
      | Ok () -> (
          match Keeper_repo_mapping.allowed_repositories ~keeper_id:"keeper-new" ~base_path with
          | Error e -> Alcotest.fail ("allowed_repositories failed: " ^ e)
          | Ok ids ->
              Alcotest.(check int) "saved count" 2 (List.length ids);
              Alcotest.(check bool) "has repo-a" true (List.mem "repo-a" ids)))

let () =
  Alcotest.run "Keeper_repo_mapping"
    [
      ( "is_allowed",
        [
          Alcotest.test_case "explicit list" `Quick test_is_allowed_explicit;
          Alcotest.test_case "wildcard" `Quick test_is_allowed_wildcard;
          Alcotest.test_case "no mapping" `Quick test_is_allowed_no_mapping;
          Alcotest.test_case "mapping parse error" `Quick
            test_is_allowed_mapping_parse_error;
          Alcotest.test_case "external mapping revocation is advisory" `Quick
            test_is_allowed_ignores_external_mapping_revocation;
        ] );
      ( "load_all",
        [
          Alcotest.test_case "malformed top-level mapping fails" `Quick
            test_load_all_rejects_non_table_mapping;
          Alcotest.test_case "wildcard scope parsed at load boundary" `Quick
            test_load_all_parses_wildcard_scope;
        ] );
      ( "validate_access",
        [
          Alcotest.test_case "allowed" `Quick test_validate_access_allowed;
          Alcotest.test_case "explicit mapping does not cap registered repo" `Quick
            test_validate_access_explicit_mapping_does_not_cap_registered_repo;
          Alcotest.test_case "no mapping" `Quick test_validate_access_no_mapping;
        ] );
      ( "validate_path_access",
        [
          Alcotest.test_case "allowed" `Quick test_validate_path_access_allowed;
          Alcotest.test_case "explicit mapping does not cap registered repo path" `Quick
            test_validate_path_access_explicit_mapping_does_not_cap_registered_repo;
          Alcotest.test_case "no repo" `Quick test_validate_path_access_no_repo;
          Alcotest.test_case "repo store load error denies" `Quick
            test_validate_path_access_rejects_repo_store_load_error;
          Alcotest.test_case "playground repo store load error denies" `Quick
            test_validate_path_access_playground_rejects_repo_store_load_error;
          Alcotest.test_case "playground repos root ignores base repo" `Quick
            test_validate_path_access_playground_repos_root_ignores_base_repo;
          Alcotest.test_case "playground repo resolves registered name" `Quick
            test_validate_path_access_playground_repo_uses_registered_name;
          Alcotest.test_case "playground repo resolves repository URL basename" `Quick
            test_validate_path_access_playground_repo_uses_url_basename;
          Alcotest.test_case "playground repo resolves explicit alias" `Quick
            test_validate_path_access_playground_repo_uses_explicit_alias;
          Alcotest.test_case "case-only URL basename drift is allowed" `Quick
            test_validate_path_access_url_basename_case_only_drift_allowed;
          Alcotest.test_case "repository identity mismatch blocks access" `Quick
            test_validate_path_access_rejects_repo_identity_mismatch;
          Alcotest.test_case "mismatched URL basename is not an alias" `Quick
            test_validate_path_access_rejects_mismatched_url_basename_alias;
          Alcotest.test_case "wildcard does not allow mismatched URL basename" `Quick
            test_validate_path_access_wildcard_rejects_mismatched_url_basename;
          Alcotest.test_case "empty URL basename is identity mismatch" `Quick
            test_validate_path_access_rejects_empty_url_basename;
          Alcotest.test_case "playground allows git remote-only visible clone" `Quick
            test_validate_path_access_playground_allows_git_remote_only_visible_clone;
          Alcotest.test_case "playground allows exact remote URL visible clone" `Quick
            test_validate_path_access_playground_allows_exact_remote_url_visible_clone;
          Alcotest.test_case "playground allows secondary remote visible clone" `Quick
            test_validate_path_access_playground_allows_secondary_remote_visible_clone;
          Alcotest.test_case "playground allows gitdir visible clone" `Quick
            test_validate_path_access_playground_allows_gitdir_visible_clone;
          Alcotest.test_case "playground large git config is allowed" `Quick
            test_validate_path_access_playground_large_git_config_allowed;
          Alcotest.test_case "playground unknown repo allowed" `Quick
            test_validate_path_access_playground_unknown_repo_allowed;
          Alcotest.test_case "playground unknown repo under wildcard allowed" `Quick
            test_validate_path_access_playground_unknown_repo_wildcard_allowed;
          Alcotest.test_case "playground unknown repo no mapping allowed" `Quick
            test_validate_path_access_playground_unknown_repo_no_mapping_allowed;
        ] );
      ( "apply_mapping",
        [
          Alcotest.test_case "explicit list" `Quick test_apply_mapping_explicit;
          Alcotest.test_case "wildcard" `Quick test_apply_mapping_wildcard;
          Alcotest.test_case "no mapping" `Quick test_apply_mapping_no_mapping;
          Alcotest.test_case "mapping parse error" `Quick
            test_apply_mapping_parse_error;
        ] );
      ( "allowed_repositories",
        [
          Alcotest.test_case "returns list" `Quick test_allowed_repositories;
          Alcotest.test_case "no mapping" `Quick test_allowed_repositories_no_mapping;
        ] );
      ( "save_mapping",
        [
          Alcotest.test_case "creates config dir" `Quick test_save_mapping_creates_config_dir;
        ] );
    ]
