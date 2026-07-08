(** Tests for Repo_store module *)

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

let is_symlink path =
  try (Unix.lstat path).st_kind = Unix.S_LNK
  with Unix.Unix_error _ | Sys_error _ -> false

let rec rm_rf path =
  if Sys.file_exists path || is_symlink path then
    if is_symlink path then Unix.unlink path
    else if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_base_path f =
  let dir = Filename.temp_file "repo_store_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let config_dir = Filename.concat dir ".masc" in
  Unix.mkdir config_dir 0o755;
  let config_subdir = Filename.concat config_dir "config" in
  Unix.mkdir config_subdir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let sample_repo id =
  {
    id;
    name = "test-repo-" ^ id;
    url = "https://github.com/test/" ^ id;
    local_path = "repos/" ^ id;
    aliases = [];
    default_branch = "main";
    keepers = [ "keeper-a"; "keeper-b" ];
    status = Active;
    auto_sync = true;
    sync_interval = 300;
    created_at = Int64.of_int 1700000000;
    updated_at = Int64.of_int 1700000100;
  }

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let init_empty_store base_path =
  let toml_path = Filename.concat (Filename.concat base_path ".masc") "config" in
  let toml_file = Filename.concat toml_path "repositories.toml" in
  write_file toml_file "[repository]\n"

let test_load_all_backward_compat () =
  with_temp_base_path (fun base_path ->
      match Repo_store.load_all ~base_path with
      | Ok repos ->
          Alcotest.(check int) "backward compat default repo" 1 (List.length repos);
          let repo = List.hd repos in
          Alcotest.(check string) "default id" "default" repo.id;
          Alcotest.(check string) "local_path is base_path" base_path repo.local_path
      | Error e -> Alcotest.fail ("unexpected error: " ^ e))

let test_save_and_load_roundtrip () =
  with_temp_base_path (fun base_path ->
      let repos = [ { (sample_repo "r1") with aliases = [ "keeper" ] }; sample_repo "r2" ] in
      match Repo_store.save_all ~base_path repos with
      | Error e -> Alcotest.fail ("save failed: " ^ e)
      | Ok () -> (
          match Repo_store.load_all ~base_path with
          | Error e -> Alcotest.fail ("load failed: " ^ e)
          | Ok loaded ->
              Alcotest.(check int) "count" 2 (List.length loaded);
              let ids = List.map (fun (r : repository) -> r.id) loaded in
              Alcotest.(check bool) "has r1" true (List.mem "r1" ids);
              Alcotest.(check bool) "has r2" true (List.mem "r2" ids);
              let r1 = List.find (fun (r : repository) -> String.equal r.id "r1") loaded in
              Alcotest.(check (list string)) "aliases roundtrip" [ "keeper" ] r1.aliases))

let test_add_new_repo () =
  with_temp_base_path (fun base_path ->
      init_empty_store base_path;
      let repo = sample_repo "new-repo" in
      match Repo_store.add ~base_path repo with
      | Error e -> Alcotest.fail ("add failed: " ^ e)
      | Ok added ->
          Alcotest.(check string) "id" "new-repo" added.id;
          match Repo_store.load_all ~base_path with
          | Ok loaded -> Alcotest.(check int) "count after add" 1 (List.length loaded)
          | Error e -> Alcotest.fail ("load after add failed: " ^ e))

let test_add_duplicate_fails () =
  with_temp_base_path (fun base_path ->
      let repo = sample_repo "dup-repo" in
      match Repo_store.add ~base_path repo with
      | Error e -> Alcotest.fail ("first add failed: " ^ e)
      | Ok _ -> (
          match Repo_store.add ~base_path repo with
          | Ok _ -> Alcotest.fail "expected error for duplicate"
          | Error msg ->
              Alcotest.(check bool) "mentions already exists" true
                (contains_substring msg "already exists")))

let test_find_existing () =
  with_temp_base_path (fun base_path ->
      let repo = sample_repo "find-me" in
      match Repo_store.add ~base_path repo with
      | Error e -> Alcotest.fail ("add failed: " ^ e)
      | Ok _ -> (
          match Repo_store.find ~base_path "find-me" with
          | Error e -> Alcotest.fail ("find failed: " ^ e)
          | Ok found -> Alcotest.(check string) "name" "test-repo-find-me" found.name))

let test_find_missing () =
  with_temp_base_path (fun base_path ->
      match Repo_store.find ~base_path "missing" with
      | Ok _ -> Alcotest.fail "expected error for missing repo"
      | Error msg ->
          Alcotest.(check bool) "mentions not found" true (contains_substring msg "not found"))

let test_remove_existing () =
  with_temp_base_path (fun base_path ->
      init_empty_store base_path;
      let repo = sample_repo "to-remove" in
      match Repo_store.add ~base_path repo with
      | Error e -> Alcotest.fail ("add failed: " ^ e)
      | Ok _ -> (
          match Repo_store.remove ~base_path "to-remove" with
          | Error e -> Alcotest.fail ("remove failed: " ^ e)
          | Ok () -> (
              match Repo_store.load_all ~base_path with
              | Ok loaded -> Alcotest.(check int) "count after remove" 0 (List.length loaded)
              | Error e -> Alcotest.fail ("load after remove failed: " ^ e))))

let test_remove_missing () =
  with_temp_base_path (fun base_path ->
      match Repo_store.remove ~base_path "missing" with
      | Ok _ -> Alcotest.fail "expected error for missing repo"
      | Error msg ->
          Alcotest.(check bool) "mentions not found" true (contains_substring msg "not found"))

let test_update_status_existing () =
  with_temp_base_path (fun base_path ->
      let repo = sample_repo "status-test" in
      match Repo_store.add ~base_path repo with
      | Error e -> Alcotest.fail ("add failed: " ^ e)
      | Ok _ -> (
          match Repo_store.update_status ~base_path "status-test" Paused with
          | Error e -> Alcotest.fail ("update_status failed: " ^ e)
          | Ok () -> (
              match Repo_store.find ~base_path "status-test" with
              | Ok found -> (
                  match found.status with
                  | Paused -> ()
                  | _ -> Alcotest.fail "expected Paused status")
              | Error e -> Alcotest.fail ("find after update failed: " ^ e))))

let test_update_status_missing () =
  with_temp_base_path (fun base_path ->
      match Repo_store.update_status ~base_path "missing" Paused with
      | Ok _ -> Alcotest.fail "expected error for missing repo"
      | Error msg ->
          Alcotest.(check bool) "mentions not found" true (contains_substring msg "not found"))

let test_update_existing () =
  with_temp_base_path (fun base_path ->
      let repo = sample_repo "update-test" in
      match Repo_store.add ~base_path repo with
      | Error e -> Alcotest.fail ("add failed: " ^ e)
      | Ok _ -> (
          let updated = { repo with name = "updated-name"; url = "https://github.com/test/updated" } in
          match Repo_store.update ~base_path "update-test" updated with
          | Error e -> Alcotest.fail ("update failed: " ^ e)
          | Ok persisted ->
              Alcotest.(check string) "name updated" "updated-name" persisted.name;
              Alcotest.(check string) "url updated" "https://github.com/test/updated" persisted.url;
              Alcotest.(check bool) "updated_at non-zero" true (Int64.compare persisted.updated_at Int64.zero > 0)))

let test_update_missing () =
  with_temp_base_path (fun base_path ->
      match Repo_store.update ~base_path "missing" (sample_repo "missing") with
      | Ok _ -> Alcotest.fail "expected error for missing repo"
      | Error msg ->
          Alcotest.(check bool) "mentions not found" true (contains_substring msg "not found"))

let test_local_path_absolute_preserved () =
  let repo = { (sample_repo "abs") with local_path = "/absolute/path" } in
  let path = Repo_store.local_path ~base_path:"/tmp/base" repo in
  Alcotest.(check string) "absolute preserved" "/absolute/path" path

let test_local_path_relative_resolved () =
  let repo = { (sample_repo "rel") with local_path = "repos/rel" } in
  let path = Repo_store.local_path ~base_path:"/tmp/base" repo in
  Alcotest.(check string) "relative resolved" "/tmp/base/repos/rel" path

let test_status_roundtrip () =
  let statuses = [ Active; Paused; Cloning; Error "network failure" ] in
  List.iter
    (fun status ->
      let str =
        match status with
        | Active -> "Active"
        | Paused -> "Paused"
        | Cloning -> "Cloning"
        | Error _ -> "Error"
      in
      Alcotest.(check string) ("status string for " ^ str) str
        (match status with
         | Active -> "Active"
         | Paused -> "Paused"
         | Cloning -> "Cloning"
         | Error _ -> "Error"))
    statuses

let test_load_minimal_toml_defaults () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/repositories.toml" in
      write_file path
        "[repository.demo]\n\
         name = \"demo\"\n\
         url = \"https://github.com/example/demo.git\"\n";
      match Repo_store.load_all ~base_path with
      | Error e -> Alcotest.fail ("load failed: " ^ e)
      | Ok [repo] ->
          Alcotest.(check string) "id" "demo" repo.id;
          Alcotest.(check string) "local_path default" ".masc/repos/demo" repo.local_path;
          Alcotest.(check string) "default branch" "main" repo.default_branch;
          Alcotest.(check bool) "auto_sync default" false repo.auto_sync;
          Alcotest.(check int) "interval default" 300 repo.sync_interval
      | Ok repos ->
          Alcotest.failf "expected one repo, got %d" (List.length repos))

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

let init_git_repo dir url =
  ignore (run_git_quiet [ "init"; dir ]);
  ignore (run_git_quiet [ "-C"; dir; "remote"; "add"; "origin"; url ])

let canonical_path path =
  try Unix.realpath path with Unix.Unix_error _ | Sys_error _ -> path

let test_discover_finds_git_repos () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let repo_a = Filename.concat base_path "project-a" in
        Unix.mkdir repo_a 0o755;
        init_git_repo repo_a "https://github.com/test/project-a";
        match Repo_store.discover_repositories ~base_path with
        | Error e -> Alcotest.fail ("discover failed: " ^ e)
        | Ok repos ->
            Alcotest.(check int) "found 1 repo" 1 (List.length repos);
            let repo = List.hd repos in
            Alcotest.(check string) "id" "project-a" repo.id;
            Alcotest.(check string) "url" "https://github.com/test/project-a" repo.url;
            Alcotest.(check string) "local_path" (canonical_path repo_a) repo.local_path)

let test_discover_ignores_masc_dir () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let masc_dir = Filename.concat base_path ".masc" in
        if not (Sys.file_exists masc_dir) then Unix.mkdir masc_dir 0o755;
        let masc_repo = Filename.concat masc_dir "internal" in
        Unix.mkdir masc_repo 0o755;
        init_git_repo masc_repo "https://github.com/test/internal";
        match Repo_store.discover_repositories ~base_path with
        | Error e -> Alcotest.fail ("discover failed: " ^ e)
        | Ok repos ->
            Alcotest.(check int) "ignores .masc repo" 0 (List.length repos))

let test_discover_finds_grouped_workspace_repos () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let workspace = Filename.concat base_path "workspace" in
        let group = Filename.concat workspace "yousleepwhen" in
        let repo_dir = Filename.concat group "oas" in
        Unix.mkdir workspace 0o755;
        Unix.mkdir group 0o755;
        Unix.mkdir repo_dir 0o755;
        init_git_repo repo_dir "https://github.com/test/oas";
        match Repo_store.discover_repositories ~base_path with
        | Error e -> Alcotest.fail ("discover failed: " ^ e)
        | Ok repos ->
            Alcotest.(check int) "finds grouped workspace repo" 1
              (List.length repos);
            let repo = List.hd repos in
            Alcotest.(check string) "id" "oas" repo.id;
            Alcotest.(check string) "local_path" (canonical_path repo_dir) repo.local_path)

let test_discover_keeps_depth_cap () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let a = Filename.concat base_path "a" in
        let b = Filename.concat a "b" in
        let c = Filename.concat b "c" in
        let d = Filename.concat c "d" in
        Unix.mkdir a 0o755;
        Unix.mkdir b 0o755;
        Unix.mkdir c 0o755;
        Unix.mkdir d 0o755;
        init_git_repo d "https://github.com/test/too-deep";
        match Repo_store.discover_repositories ~base_path with
        | Error e -> Alcotest.fail ("discover failed: " ^ e)
        | Ok repos ->
            Alcotest.(check int) "ignores repo beyond max depth" 0
              (List.length repos))

let test_discover_ignores_hidden_dirs () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let cache_dir = Filename.concat base_path ".cache" in
        let cache_repo = Filename.concat cache_dir "llama.cpp" in
        Unix.mkdir cache_dir 0o755;
        Unix.mkdir cache_repo 0o755;
        init_git_repo cache_repo "https://github.com/test/llama.cpp";
        match Repo_store.discover_repositories ~base_path with
        | Error e -> Alcotest.fail ("discover failed: " ^ e)
        | Ok repos ->
            Alcotest.(check int) "ignores hidden directory repo" 0
              (List.length repos))

let test_discover_ignores_symlink_dirs () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let outside = Filename.temp_file "repo_store_outside" "" in
        Sys.remove outside;
        Unix.mkdir outside 0o755;
        Fun.protect
          ~finally:(fun () -> rm_rf outside)
          (fun () ->
            init_git_repo outside "https://github.com/test/outside";
            let link = Filename.concat base_path "linked-outside" in
            (try Unix.symlink outside link
             with Unix.Unix_error _ -> Alcotest.skip ());
            match Repo_store.discover_repositories ~base_path with
            | Error e -> Alcotest.fail ("discover failed: " ^ e)
            | Ok repos ->
                Alcotest.(check int) "ignores symlink directory repo" 0
                  (List.length repos)))

let test_discover_relative_base_path_keeps_visible_repos () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let repo_a = Filename.concat base_path "project-a" in
        Unix.mkdir repo_a 0o755;
        init_git_repo repo_a "https://github.com/test/project-a";
        let cwd = Sys.getcwd () in
        Fun.protect
          ~finally:(fun () -> Sys.chdir cwd)
          (fun () ->
            Sys.chdir base_path;
            match Repo_store.discover_repositories ~base_path:"." with
            | Error e -> Alcotest.fail ("discover failed: " ^ e)
            | Ok repos ->
                Alcotest.(check int) "finds visible repo under relative base" 1
                  (List.length repos);
                let repo = List.hd repos in
                Alcotest.(check string) "id" "project-a" repo.id))

let test_migration_backward_compat_to_explicit () =
  with_temp_base_path (fun base_path ->
      (* Phase 1: no TOML — backward compat returns default repo *)
      match Repo_store.load_all ~base_path with
      | Error e -> Alcotest.fail ("load failed: " ^ e)
      | Ok repos ->
          Alcotest.(check int) "backward compat count" 1 (List.length repos);
          let default = List.hd repos in
          Alcotest.(check string) "default id" "default" default.id;
          (* Phase 2: operator discovers and adds explicit repos *)
          let explicit = sample_repo "migrated" in
          (match Repo_store.add ~base_path explicit with
           | Error e -> Alcotest.fail ("add failed: " ^ e)
           | Ok _ -> (
               match Repo_store.load_all ~base_path with
               | Error e -> Alcotest.fail ("load after migration failed: " ^ e)
               | Ok migrated ->
                   Alcotest.(check int) "migrated count" 2 (List.length migrated);
                   let ids = List.map (fun (r : repository) -> r.id) migrated in
                   Alcotest.(check bool) "has default" true (List.mem "default" ids);
                   Alcotest.(check bool) "has migrated" true (List.mem "migrated" ids))))

let test_migration_preserves_existing_toml () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/repositories.toml" in
      write_file path
        "[repository.existing]\n\
         name = \"existing\"\n\
         url = \"https://github.com/test/existing.git\"\n";
      (* TOML exists — backward compat must NOT inject default *)
      match Repo_store.load_all ~base_path with
      | Error e -> Alcotest.fail ("load failed: " ^ e)
      | Ok repos ->
          Alcotest.(check int) "existing toml count" 1 (List.length repos);
          Alcotest.(check string) "existing id" "existing" (List.hd repos).id)

let test_discover_skips_registered () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let repo_a = Filename.concat base_path "project-a" in
        Unix.mkdir repo_a 0o755;
        init_git_repo repo_a "https://github.com/test/project-a";
        match
          Repo_store.save_all ~base_path
            [ { (sample_repo "project-a") with local_path = repo_a } ]
        with
        | Error e -> Alcotest.fail ("save failed: " ^ e)
        | Ok () -> (
            match Repo_store.discover_repositories ~base_path with
            | Error e -> Alcotest.fail ("discover failed: " ^ e)
            | Ok repos ->
                Alcotest.(check int) "skips already registered" 0
                  (List.length repos)))

let test_register_discovered_auto_adds () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let repo_a = Filename.concat base_path "project-a" in
        let repo_b = Filename.concat base_path "project-b" in
        Unix.mkdir repo_a 0o755;
        Unix.mkdir repo_b 0o755;
        init_git_repo repo_a "https://github.com/test/project-a";
        init_git_repo repo_b "https://github.com/test/project-b";
        match Repo_store.register_discovered ~base_path with
        | Error e -> Alcotest.fail ("register_discovered failed: " ^ e)
        | Ok registered ->
            Alcotest.(check int) "registered 2 repos" 2 (List.length registered);
            let ids = List.map (fun (r : repository) -> r.id) registered in
            Alcotest.(check bool) "has project-a" true (List.mem "project-a" ids);
            Alcotest.(check bool) "has project-b" true (List.mem "project-b" ids);
            (* Verify TOML now exists and contains both *)
            match Repo_store.load_all ~base_path with
            | Error e -> Alcotest.fail ("load after register failed: " ^ e)
            | Ok loaded ->
                Alcotest.(check int) "persisted 2 repos" 2 (List.length loaded))

let test_register_discovered_includes_legacy_root_repo () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let repo_b = Filename.concat base_path "project-b" in
        Unix.mkdir repo_b 0o755;
        init_git_repo base_path "https://github.com/test/root-repo";
        init_git_repo repo_b "https://github.com/test/project-b";
        match Repo_store.register_discovered ~base_path with
        | Error e -> Alcotest.fail ("register_discovered failed: " ^ e)
        | Ok registered ->
            Alcotest.(check int) "registered 2 repos" 2 (List.length registered);
            let ids = List.map (fun (r : repository) -> r.id) registered in
            let has_root =
              List.exists
                (fun (r : repository) ->
                  String.equal r.local_path (canonical_path base_path))
                registered
            in
            Alcotest.(check bool) "has root repo at base_path" true has_root;
            Alcotest.(check bool) "has project-b" true (List.mem "project-b" ids);
            match Repo_store.load_all ~base_path with
            | Error e -> Alcotest.fail ("load after register failed: " ^ e)
            | Ok loaded ->
                let persisted_root =
                  List.exists
                    (fun (r : repository) ->
                      String.equal r.local_path (canonical_path base_path))
                    loaded
                in
                Alcotest.(check int) "persisted 2 repos" 2 (List.length loaded);
                Alcotest.(check bool) "persisted root repo at base_path" true
                  persisted_root)

let test_register_discovered_skips_existing () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
        let repo_a = Filename.concat base_path "project-a" in
        Unix.mkdir repo_a 0o755;
        init_git_repo repo_a "https://github.com/test/project-a";
        (* First call registers *)
        (match Repo_store.register_discovered ~base_path with
         | Error e -> Alcotest.fail ("first register failed: " ^ e)
         | Ok first -> Alcotest.(check int) "first count" 1 (List.length first));
        (* Second call should skip and return empty *)
        match Repo_store.register_discovered ~base_path with
        | Error e -> Alcotest.fail ("second register failed: " ^ e)
        | Ok second ->
            Alcotest.(check int) "second count empty" 0 (List.length second))

(* RFC-0128 §4.5 — reverse lookup tests. *)

let with_two_absolute_repos f =
  with_temp_base_path (fun base_path ->
    init_empty_store base_path;
    let masc_path = Filename.concat base_path "workspace/masc" in
    let oas_path = Filename.concat base_path "workspace/oas" in
    Unix.mkdir (Filename.concat base_path "workspace") 0o755;
    Unix.mkdir masc_path 0o755;
    Unix.mkdir oas_path 0o755;
    let masc =
      { (sample_repo "masc") with
        url = "https://github.com/jeong-sik/masc"
      ; local_path = masc_path
      ; aliases = [ "masc-mcp" ]
      }
    in
    let oas =
      { (sample_repo "oas") with
        url = "https://github.com/jeong-sik/oas"
      ; local_path = oas_path
      }
    in
    (match Repo_store.save_all ~base_path [ masc; oas ] with
     | Ok () -> ()
     | Error e -> Alcotest.fail ("save_all: " ^ e));
    f ~base_path ~masc_path ~oas_path)

let test_find_url_by_id_known () =
  with_two_absolute_repos (fun ~base_path ~masc_path:_ ~oas_path:_ ->
    match Repo_store.find_url_by_id ~base_path "masc" with
    | Some url ->
      Alcotest.(check string)
        "masc url"
        "https://github.com/jeong-sik/masc"
        url
    | None -> Alcotest.fail "expected Some url for masc")

let test_find_url_by_id_unknown () =
  with_two_absolute_repos (fun ~base_path ~masc_path:_ ~oas_path:_ ->
    match Repo_store.find_url_by_id ~base_path "nonexistent" with
    | None -> ()
    | Some s -> Alcotest.fail ("expected None for unknown, got: " ^ s))

let test_find_url_by_identity_alias () =
  with_two_absolute_repos (fun ~base_path ~masc_path:_ ~oas_path:_ ->
    match Repo_store.find_url_by_identity ~base_path "masc-mcp" with
    | Some url ->
      Alcotest.(check string)
        "masc alias url"
        "https://github.com/jeong-sik/masc"
        url
    | None -> Alcotest.fail "expected Some url for masc-mcp alias")

let test_find_url_by_identity_ambiguous_alias () =
  with_temp_base_path (fun base_path ->
    init_empty_store base_path;
    let workspace = Filename.concat base_path "workspace" in
    Unix.mkdir workspace 0o755;
    let left_path = Filename.concat workspace "left" in
    let right_path = Filename.concat workspace "right" in
    Unix.mkdir left_path 0o755;
    Unix.mkdir right_path 0o755;
    let left =
      { (sample_repo "left") with
        url = "https://github.com/example/left"
      ; local_path = left_path
      ; aliases = [ "shared" ]
      }
    in
    let right =
      { (sample_repo "right") with
        url = "https://github.com/example/right"
      ; local_path = right_path
      ; aliases = [ "shared" ]
      }
    in
    (match Repo_store.save_all ~base_path [ left; right ] with
     | Ok () -> ()
     | Error e -> Alcotest.fail ("save_all: " ^ e));
    match Repo_store.find_url_by_identity ~base_path "shared" with
    | None -> ()
    | Some url -> Alcotest.fail ("ambiguous alias must not pick url: " ^ url))

let test_find_repo_by_path_prefix_match () =
  with_two_absolute_repos (fun ~base_path ~masc_path ~oas_path:_ ->
    let abs = Filename.concat masc_path "lib/foo.ml" in
    match Repo_store.find_repo_by_path_prefix ~base_path abs with
    | Some (repo, rel) ->
      Alcotest.(check string) "matched repo id" "masc" repo.id;
      Alcotest.(check string) "relative path" "lib/foo.ml" rel
    | None -> Alcotest.fail "expected match under masc_path")

let test_find_repo_by_path_prefix_outside () =
  with_two_absolute_repos (fun ~base_path ~masc_path:_ ~oas_path:_ ->
    match Repo_store.find_repo_by_path_prefix ~base_path "/tmp/elsewhere.ml" with
    | None -> ()
    | Some (repo, _) ->
      Alcotest.fail ("unexpected match: " ^ repo.id))

let test_find_repo_by_path_prefix_sibling_not_matched () =
  (* Sibling-style collision: /tmp/masc and /tmp/masc-mirror must not
     match each other's paths. Guards against pure-substring prefix. *)
  with_temp_base_path (fun base_path ->
    init_empty_store base_path;
    let workspace = Filename.concat base_path "workspace" in
    Unix.mkdir workspace 0o755;
    let masc = Filename.concat workspace "masc" in
    let mirror = Filename.concat workspace "masc-mirror" in
    Unix.mkdir masc 0o755;
    Unix.mkdir mirror 0o755;
    let r1 =
      { (sample_repo "masc") with
        url = "https://github.com/owner/masc"
      ; local_path = masc
      }
    in
    let r2 =
      { (sample_repo "mirror") with
        url = "https://github.com/owner/masc-mirror"
      ; local_path = mirror
      }
    in
    (match Repo_store.save_all ~base_path [ r1; r2 ] with
     | Ok () -> ()
     | Error e -> Alcotest.fail ("save_all: " ^ e));
    let inside_mirror = Filename.concat mirror "lib/x.ml" in
    match Repo_store.find_repo_by_path_prefix ~base_path inside_mirror with
    | Some (repo, rel) ->
      Alcotest.(check string) "must pick mirror, not masc" "mirror" repo.id;
      Alcotest.(check string) "rel" "lib/x.ml" rel
    | None -> Alcotest.fail "expected match under mirror")

let test_find_repo_by_path_prefix_root () =
  (* abs_path equals the repo's local_path itself → empty rel. *)
  with_two_absolute_repos (fun ~base_path ~masc_path ~oas_path:_ ->
    match Repo_store.find_repo_by_path_prefix ~base_path masc_path with
    | Some (repo, rel) ->
      Alcotest.(check string) "matched repo id" "masc" repo.id;
      Alcotest.(check string) "empty rel at root" "" rel
    | None -> Alcotest.fail "expected match at repo root")

let () =
  Alcotest.run "Repo_store"
    [
      ( "roundtrip",
        [
          Alcotest.test_case "backward compat default" `Quick test_load_all_backward_compat;
          Alcotest.test_case "save and load roundtrip" `Quick test_save_and_load_roundtrip;
        ] );
      ( "add",
        [
          Alcotest.test_case "add new repo" `Quick test_add_new_repo;
          Alcotest.test_case "add duplicate fails" `Quick test_add_duplicate_fails;
        ] );
      ( "find",
        [
          Alcotest.test_case "find existing" `Quick test_find_existing;
          Alcotest.test_case "find missing" `Quick test_find_missing;
        ] );
      ( "remove",
        [
          Alcotest.test_case "remove existing" `Quick test_remove_existing;
          Alcotest.test_case "remove missing" `Quick test_remove_missing;
        ] );
      ( "update_status",
        [
          Alcotest.test_case "update existing" `Quick test_update_status_existing;
          Alcotest.test_case "update missing" `Quick test_update_status_missing;
        ] );
      ( "update",
        [
          Alcotest.test_case "update existing" `Quick test_update_existing;
          Alcotest.test_case "update missing" `Quick test_update_missing;
        ] );
      ( "local_path",
        [
          Alcotest.test_case "absolute preserved" `Quick test_local_path_absolute_preserved;
          Alcotest.test_case "relative resolved" `Quick test_local_path_relative_resolved;
        ] );
      ( "status",
        [
          Alcotest.test_case "status string roundtrip" `Quick test_status_roundtrip;
        ] );
      ( "defaults",
        [
          Alcotest.test_case "minimal TOML gets production defaults" `Quick
            test_load_minimal_toml_defaults;
        ] );
      ( "discover",
        [
          Alcotest.test_case "finds git repos" `Quick test_discover_finds_git_repos;
          Alcotest.test_case "ignores .masc repos" `Quick test_discover_ignores_masc_dir;
          Alcotest.test_case "finds grouped workspace repos" `Quick
            test_discover_finds_grouped_workspace_repos;
          Alcotest.test_case "keeps max depth cap" `Quick
            test_discover_keeps_depth_cap;
          Alcotest.test_case "ignores hidden dirs" `Quick
            test_discover_ignores_hidden_dirs;
          Alcotest.test_case "ignores symlink dirs" `Quick
            test_discover_ignores_symlink_dirs;
          Alcotest.test_case "relative base path keeps visible repos" `Quick
            test_discover_relative_base_path_keeps_visible_repos;
          Alcotest.test_case "skips registered repos" `Quick test_discover_skips_registered;
        ] );
      ( "migration",
        [
          Alcotest.test_case "backward compat to explicit" `Quick
            test_migration_backward_compat_to_explicit;
          Alcotest.test_case "preserves existing toml" `Quick
            test_migration_preserves_existing_toml;
          Alcotest.test_case "register_discovered auto-adds" `Quick
            test_register_discovered_auto_adds;
          Alcotest.test_case "register_discovered includes legacy root repo" `Quick
            test_register_discovered_includes_legacy_root_repo;
          Alcotest.test_case "register_discovered skips existing" `Quick
            test_register_discovered_skips_existing;
        ] );
      ( "reverse_lookup (RFC-0128)",
        [
          Alcotest.test_case "find_url_by_id known" `Quick test_find_url_by_id_known;
          Alcotest.test_case "find_url_by_id unknown" `Quick test_find_url_by_id_unknown;
          Alcotest.test_case "find_url_by_identity alias" `Quick
            test_find_url_by_identity_alias;
          Alcotest.test_case "find_url_by_identity ambiguous alias" `Quick
            test_find_url_by_identity_ambiguous_alias;
          Alcotest.test_case "path_prefix match" `Quick test_find_repo_by_path_prefix_match;
          Alcotest.test_case "path_prefix outside" `Quick test_find_repo_by_path_prefix_outside;
          Alcotest.test_case "path_prefix sibling-safe" `Quick
            test_find_repo_by_path_prefix_sibling_not_matched;
          Alcotest.test_case "path_prefix at repo root" `Quick test_find_repo_by_path_prefix_root;
        ] );
    ]
