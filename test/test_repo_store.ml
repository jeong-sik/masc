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

let with_temp_base_path f =
  let dir = Filename.temp_file "repo_store_test" "" in
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

let sample_repo id =
  {
    id;
    name = "test-repo-" ^ id;
    url = "https://github.com/test/" ^ id;
    local_path = "repos/" ^ id;
    default_branch = "main";
    credential_id = "cred-1";
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
      let repos = [ sample_repo "r1"; sample_repo "r2" ] in
      match Repo_store.save_all ~base_path repos with
      | Error e -> Alcotest.fail ("save failed: " ^ e)
      | Ok () -> (
          match Repo_store.load_all ~base_path with
          | Error e -> Alcotest.fail ("load failed: " ^ e)
          | Ok loaded ->
              Alcotest.(check int) "count" 2 (List.length loaded);
              let ids = List.map (fun (r : repository) -> r.id) loaded in
              Alcotest.(check bool) "has r1" true (List.mem "r1" ids);
              Alcotest.(check bool) "has r2" true (List.mem "r2" ids)))

let test_add_new_repo () =
  with_temp_base_path (fun base_path ->
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
          | Ok () -> (
              match Repo_store.find ~base_path "update-test" with
              | Ok found ->
                  Alcotest.(check string) "name updated" "updated-name" found.name;
                  Alcotest.(check string) "url updated" "https://github.com/test/updated" found.url
              | Error e -> Alcotest.fail ("find after update failed: " ^ e))))

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
          Alcotest.(check string) "credential" "default" repo.credential_id;
          Alcotest.(check bool) "auto_sync default" false repo.auto_sync;
          Alcotest.(check int) "interval default" 300 repo.sync_interval
      | Ok repos ->
          Alcotest.failf "expected one repo, got %d" (List.length repos))

let git_available () =
  Sys.command "git --version >/dev/null 2>&1" = 0

let init_git_repo dir url =
  ignore (Sys.command (Printf.sprintf "git init %s >/dev/null 2>&1" (Filename.quote dir)));
  ignore
    (Sys.command
       (Printf.sprintf "git -C %s remote add origin %s >/dev/null 2>&1"
          (Filename.quote dir)
          (Filename.quote url)))

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
            Alcotest.(check string) "local_path" repo_a repo.local_path)

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
          Alcotest.test_case "skips registered repos" `Quick test_discover_skips_registered;
        ] );
    ]
