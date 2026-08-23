(** Tests for Repo_store module *)

open Repo_manager_types

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

(* Two records for one upstream clone to two directory names, so a keeper
   reaching the repository by id lands in a different checkout than one
   reaching it by path basename. That is what produced the cwd_not_directory
   failures in #21837, and the [aliases] field cannot fix it — routing an alias
   hides the duplicate instead of removing it. *)
let test_load_all_rejects_two_records_for_one_upstream () =
  with_temp_base_path (fun base_path ->
    let first = { (sample_repo "masc") with url = "https://github.com/o/r" } in
    let second = { (sample_repo "masc-mcp") with url = "git@github.com:o/r.git" } in
    match Repo_store.save_all ~base_path [ first; second ] with
    | Error msg -> Alcotest.failf "save_all failed: %s" msg
    | Ok () ->
      (match Repo_store.load_all ~base_path with
       | Ok repos ->
         Alcotest.failf
           "two records for one upstream loaded as %d repositories"
           (List.length repos)
       | Error msg ->
         Alcotest.(check bool)
           "the error names both records"
           true
           (let has needle =
              let n = String.length needle and h = String.length msg in
              let rec scan i = i + n <= h && (String.sub msg i n = needle || scan (i + 1)) in
              scan 0
            in
            has "repository.masc" && has "repository.masc-mcp")))
;;

let test_load_all_accepts_distinct_upstreams () =
  with_temp_base_path (fun base_path ->
    let first = { (sample_repo "alpha") with url = "https://github.com/o/alpha" } in
    let second = { (sample_repo "beta") with url = "https://github.com/o/beta" } in
    match Repo_store.save_all ~base_path [ first; second ] with
    | Error msg -> Alcotest.failf "save_all failed: %s" msg
    | Ok () ->
      (match Repo_store.load_all ~base_path with
       | Ok repos -> Alcotest.(check int) "both load" 2 (List.length repos)
       | Error msg -> Alcotest.failf "distinct upstreams rejected: %s" msg))
;;

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let init_empty_store base_path =
  let toml_path = Filename.concat (Filename.concat base_path ".masc") "config" in
  let toml_file = Filename.concat toml_path "repositories.toml" in
  write_file toml_file "[repository]\n"

let complete_repository_toml ?(aliases = "[]") ?(status = "Active")
    ?status_error () =
  let status_error =
    match status_error with
    | None -> ""
    | Some message -> Printf.sprintf "status_error = \"%s\"\n" message
  in
  Printf.sprintf
    "[repository.demo]\n\
     name = \"demo\"\n\
     url = \"https://github.com/example/demo.git\"\n\
     local_path = \"repos/demo\"\n\
     aliases = %s\n\
     default_branch = \"main\"\n\
     keepers = []\n\
     status = \"%s\"\n\
     %s\
     auto_sync = false\n\
     sync_interval = 300\n\
     created_at = 1700000000\n\
     updated_at = 1700000100\n"
    aliases status status_error

let test_load_missing_catalog_is_empty () =
  with_temp_base_path (fun base_path ->
      match Repo_store.load_all ~base_path with
      | Ok repos -> Alcotest.(check int) "empty catalog" 0 (List.length repos)
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

let test_empty_catalog_roundtrip () =
  with_temp_base_path (fun base_path ->
      match Repo_store.save_all ~base_path [] with
      | Error error -> Alcotest.fail ("save failed: " ^ error)
      | Ok () ->
        match Repo_store.load_all ~base_path with
        | Error error -> Alcotest.fail ("load failed: " ^ error)
        | Ok repositories ->
          Alcotest.(check int) "explicit empty catalog" 0
            (List.length repositories))

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
              (String_util.contains_substring msg "already exists")))

let test_add_rejects_blank_local_path () =
  with_temp_base_path (fun base_path ->
      let repository = { (sample_repo "blank") with local_path = "  " } in
      match Repo_store.add ~base_path repository with
      | Ok _ -> Alcotest.fail "blank local_path must be rejected"
      | Error error ->
        Alcotest.(check bool) "names local_path" true
          (String_util.contains_substring error "local_path"))

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
          Alcotest.(check bool) "mentions not found" true (String_util.contains_substring msg "not found"))

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
          Alcotest.(check bool) "mentions not found" true (String_util.contains_substring msg "not found"))

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
          Alcotest.(check bool) "mentions not found" true (String_util.contains_substring msg "not found"))

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
          Alcotest.(check bool) "mentions not found" true (String_util.contains_substring msg "not found"))

let test_update_rejects_blank_local_path () =
  with_temp_base_path (fun base_path ->
      let repository = sample_repo "update-blank" in
      match Repo_store.add ~base_path repository with
      | Error error -> Alcotest.fail ("add failed: " ^ error)
      | Ok _ ->
        let update = { repository with local_path = "" } in
        match Repo_store.update ~base_path repository.id update with
        | Ok _ -> Alcotest.fail "blank local_path must be rejected"
        | Error error ->
          Alcotest.(check bool) "names local_path" true
            (String_util.contains_substring error "local_path"))

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
  with_temp_base_path (fun base_path ->
      List.iteri
        (fun index status ->
          let repository = { (sample_repo (string_of_int index)) with status } in
          match Repo_store.save_all ~base_path [ repository ] with
          | Error error -> Alcotest.fail ("save failed: " ^ error)
          | Ok () ->
            match Repo_store.load_all ~base_path with
            | Error error -> Alcotest.fail ("load failed: " ^ error)
            | Ok [ loaded ] ->
              Alcotest.(check bool) "status roundtrip" true
                (equal_repository_status status loaded.status)
            | Ok repositories ->
              Alcotest.failf "expected one repository, got %d"
                (List.length repositories))
        statuses)

let test_load_rejects_incomplete_repository () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/repositories.toml" in
      write_file path
        "[repository.demo]\n\
         name = \"demo\"\n\
         url = \"https://github.com/example/demo.git\"\n";
      match Repo_store.load_all ~base_path with
      | Ok _ -> Alcotest.fail "incomplete repository row must be rejected"
      | Error error ->
          Alcotest.(check bool) "names first missing field" true
            (String_util.contains_substring error "repository.demo.local_path"))

let test_load_rejects_missing_repository_table () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/repositories.toml" in
      write_file path "";
      match Repo_store.load_all ~base_path with
      | Ok _ -> Alcotest.fail "catalog without repository table must be rejected"
      | Error error ->
          Alcotest.(check bool) "names required table" true
            (String_util.contains_substring error "required repository table"))

let test_load_rejects_unknown_top_level_field () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/repositories.toml" in
      write_file path "answer = 42\n";
      match Repo_store.load_all ~base_path with
      | Ok _ -> Alcotest.fail "unknown top-level field must be rejected"
      | Error error ->
        Alcotest.(check bool) "names unknown top-level field" true
          (String_util.contains_substring error "unknown top-level field answer"))

let test_load_rejects_noncanonical_status () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/repositories.toml" in
      write_file path
        "[repository.demo]\n\
         name = \"demo\"\n\
         url = \"https://github.com/example/demo.git\"\n\
         local_path = \"repos/demo\"\n\
         aliases = []\n\
         default_branch = \"main\"\n\
         keepers = []\n\
         status = \"active\"\n\
         auto_sync = false\n\
         sync_interval = 300\n\
         created_at = 1700000000\n\
         updated_at = 1700000100\n";
      match Repo_store.load_all ~base_path with
      | Ok _ -> Alcotest.fail "noncanonical status must be rejected"
      | Error error ->
          Alcotest.(check bool) "names rejected status" true
            (String_util.contains_substring error "Unknown repository status: active"))

let test_load_rejects_unknown_field () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/repositories.toml" in
      write_file path
        "[repository.demo]\n\
         name = \"demo\"\n\
         url = \"https://github.com/example/demo.git\"\n\
         local_path = \"repos/demo\"\n\
         aliases = []\n\
         default_branch = \"main\"\n\
         keepers = []\n\
         status = \"Active\"\n\
         auto_sync = false\n\
         sync_interval = 300\n\
         created_at = 1700000000\n\
         updated_at = 1700000100\n\
         retired_path = \"old\"\n";
      match Repo_store.load_all ~base_path with
      | Ok _ -> Alcotest.fail "unknown repository field must be rejected"
      | Error error ->
          Alcotest.(check bool) "names unknown field" true
            (String_util.contains_substring error "repository.demo.retired_path"))

let test_load_rejects_wrong_field_type () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/repositories.toml" in
      write_file path (complete_repository_toml ~aliases:"\"alias\"" ());
      match Repo_store.load_all ~base_path with
      | Ok _ -> Alcotest.fail "wrong field type must be rejected"
      | Error error ->
        Alcotest.(check bool) "names wrong field" true
          (String_util.contains_substring error "repository.demo.aliases"))

let test_error_status_requires_message () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/repositories.toml" in
      write_file path (complete_repository_toml ~status:"Error" ());
      match Repo_store.load_all ~base_path with
      | Ok _ -> Alcotest.fail "Error status without status_error must be rejected"
      | Error error ->
        Alcotest.(check bool) "names required status_error" true
          (String_util.contains_substring error "repository.demo.status_error"))

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
        let repo_dir = Filename.concat group "agent_core" in
        Unix.mkdir workspace 0o755;
        Unix.mkdir group 0o755;
        Unix.mkdir repo_dir 0o755;
        init_git_repo repo_dir "https://example.com/agent-core";
        match Repo_store.discover_repositories ~base_path with
        | Error e -> Alcotest.fail ("discover failed: " ^ e)
        | Ok repos ->
            Alcotest.(check int) "finds grouped workspace repo" 1
              (List.length repos);
            let repo = List.hd repos in
            Alcotest.(check string) "id" "agent_core" repo.id;
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

let test_discover_origin_budget_is_cumulative () =
  with_temp_base_path (fun base_path ->
    let fake_bin = Filename.concat base_path "fake-bin" in
    Unix.mkdir fake_bin 0o755;
    let fake_git = Filename.concat fake_bin "git" in
    write_file fake_git "#!/bin/sh\nexec sleep 30\n";
    Unix.chmod fake_git 0o755;
    List.iter
      (fun name ->
         let repo = Filename.concat base_path name in
         Unix.mkdir repo 0o755;
         Unix.mkdir (Filename.concat repo ".git") 0o755)
      [ "stalled-a"; "stalled-b" ];
    let old_path = Sys.getenv "PATH" in
    Fun.protect
      ~finally:(fun () -> Unix.putenv "PATH" old_path)
      (fun () ->
         Unix.putenv "PATH" (fake_bin ^ ":" ^ old_path);
         let started_at = Unix.gettimeofday () in
         let result =
           Repo_store.For_testing.discover_repositories_with_budget
             ~origin_budget_sec:0.2
             ~base_path
         in
         let elapsed = Unix.gettimeofday () -. started_at in
         (match result with
          | Error _ -> ()
          | Ok _ -> Alcotest.fail "exhausted discovery budget returned a partial success");
         Alcotest.(check bool)
           "two stalled repositories share one request budget"
           true
           (elapsed < 1.0)))
;;

let test_discover_timeout_on_last_candidate_is_typed_failure () =
  with_temp_base_path (fun base_path ->
    let fake_bin = Filename.concat base_path "fake-bin" in
    Unix.mkdir fake_bin 0o755;
    let fake_git = Filename.concat fake_bin "git" in
    write_file fake_git "#!/bin/sh\nexec sleep 30\n";
    Unix.chmod fake_git 0o755;
    let repo = Filename.concat base_path "stalled-only" in
    Unix.mkdir repo 0o755;
    Unix.mkdir (Filename.concat repo ".git") 0o755;
    let old_path = Sys.getenv "PATH" in
    Fun.protect
      ~finally:(fun () -> Unix.putenv "PATH" old_path)
      (fun () ->
         Unix.putenv "PATH" (fake_bin ^ ":" ^ old_path);
         let started_at = Unix.gettimeofday () in
         let result =
           Repo_store.For_testing.discover_repositories_with_budget
             ~origin_budget_sec:0.2
             ~base_path
         in
         let elapsed = Unix.gettimeofday () -. started_at in
         (match result with
          | Error _ -> ()
          | Ok _ -> Alcotest.fail "timed-out final origin was silently skipped");
         Alcotest.(check bool) "still bounded by the budget" true (elapsed < 1.0)))
;;

let test_discover_skips_missing_origin_without_failing_request () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
      let without_origin = Filename.concat base_path "without-origin" in
      Unix.mkdir without_origin 0o755;
      init_git_repo without_origin "https://github.com/test/temporary";
      (match Repo_git.run_git ~cwd:without_origin [ "remote"; "remove"; "origin" ] with
       | Ok _ -> ()
       | Error detail -> Alcotest.fail detail);
      let with_origin = Filename.concat base_path "with-origin" in
      Unix.mkdir with_origin 0o755;
      init_git_repo with_origin "https://github.com/test/with-origin";
      match Repo_store.discover_repositories ~base_path with
      | Error detail ->
        Alcotest.fail ("missing origin failed repository discovery: " ^ detail)
      | Ok repos ->
        Alcotest.(check (list string))
          "missing-origin repository is skipped while valid candidates survive"
          [ "with-origin" ]
          (List.map (fun (repo : repository) -> repo.id) repos))
;;

let test_discover_origin_budget_starts_after_filesystem_scan () =
  if not (git_available ()) then Alcotest.skip ()
  else
    with_temp_base_path (fun base_path ->
      let repo = Filename.concat base_path "fast-origin" in
      Unix.mkdir repo 0o755;
      init_git_repo repo "https://github.com/test/fast-origin";
      match
        Repo_store.For_testing.discover_repositories_with_budget_after_scan
          ~before_origin_inspection:(fun () -> Unix.sleepf 0.25)
          ~origin_budget_sec:0.2
          ~base_path
      with
      | Error detail ->
        Alcotest.fail ("filesystem discovery consumed origin budget: " ^ detail)
      | Ok repos ->
        Alcotest.(check int) "fast origin remains inspectable" 1 (List.length repos))
;;

let test_discovery_warning_escapes_untrusted_fields () =
  let line =
    Repo_store.For_testing.discovery_skip_log_line
      ~abs_repo_dir:"/tmp/repo\nforged"
      ~detail:"fatal:\027[31mred"
  in
  Alcotest.(check string)
    "newline and terminal escape are rendered as quoted escapes"
    "repo discovery skipped \"/tmp/repo\\nforged\": origin unavailable (\"fatal:\\027[31mred\")"
    line
;;

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

let test_register_discovered_includes_root_repo () =
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
    let agent_core_path = Filename.concat base_path "workspace/agent_core" in
    Unix.mkdir (Filename.concat base_path "workspace") 0o755;
    Unix.mkdir masc_path 0o755;
    Unix.mkdir agent_core_path 0o755;
    let masc =
      { (sample_repo "masc") with
        url = "https://github.com/jeong-sik/masc"
      ; local_path = masc_path
      ; aliases = [ "masc-mcp" ]
      }
    in
    let agent_core =
      { (sample_repo "agent_core") with
        url = "https://example.com/agent-core"
      ; local_path = agent_core_path
      }
    in
    (match Repo_store.save_all ~base_path [ masc; agent_core ] with
     | Ok () -> ()
     | Error e -> Alcotest.fail ("save_all: " ^ e));
    f ~base_path ~masc_path ~agent_core_path)

let test_find_url_by_id_known () =
  with_two_absolute_repos (fun ~base_path ~masc_path:_ ~agent_core_path:_ ->
    match Repo_store.find_url_by_id ~base_path "masc" with
    | Ok (Some url) ->
      Alcotest.(check string)
        "masc url"
        "https://github.com/jeong-sik/masc"
        url
    | Ok None -> Alcotest.fail "expected Some url for masc"
    | Error error -> Alcotest.fail ("lookup failed: " ^ error))

let test_find_url_by_id_unknown () =
  with_two_absolute_repos (fun ~base_path ~masc_path:_ ~agent_core_path:_ ->
    match Repo_store.find_url_by_id ~base_path "nonexistent" with
    | Ok None -> ()
    | Ok (Some s) -> Alcotest.fail ("expected None for unknown, got: " ^ s)
    | Error error -> Alcotest.fail ("lookup failed: " ^ error))

let test_find_repo_by_path_prefix_match () =
  with_two_absolute_repos (fun ~base_path ~masc_path ~agent_core_path:_ ->
    let abs = Filename.concat masc_path "lib/foo.ml" in
    match Repo_store.find_repo_by_path_prefix ~base_path abs with
    | Ok (Some (repo, rel)) ->
      Alcotest.(check string) "matched repo id" "masc" repo.id;
      Alcotest.(check string) "relative path" "lib/foo.ml" rel
    | Ok None -> Alcotest.fail "expected match under masc_path"
    | Error error -> Alcotest.fail ("lookup failed: " ^ error))

let test_find_repo_by_path_prefix_outside () =
  with_two_absolute_repos (fun ~base_path ~masc_path:_ ~agent_core_path:_ ->
    match Repo_store.find_repo_by_path_prefix ~base_path "/tmp/elsewhere.ml" with
    | Ok None -> ()
    | Ok (Some (repo, _)) -> Alcotest.fail ("unexpected match: " ^ repo.id)
    | Error error -> Alcotest.fail ("lookup failed: " ^ error))

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
    | Ok (Some (repo, rel)) ->
      Alcotest.(check string) "must pick mirror, not masc" "mirror" repo.id;
      Alcotest.(check string) "rel" "lib/x.ml" rel
    | Ok None -> Alcotest.fail "expected match under mirror"
    | Error error -> Alcotest.fail ("lookup failed: " ^ error))

let test_find_repo_by_path_prefix_root () =
  (* abs_path equals the repo's local_path itself → empty rel. *)
  with_two_absolute_repos (fun ~base_path ~masc_path ~agent_core_path:_ ->
    match Repo_store.find_repo_by_path_prefix ~base_path masc_path with
    | Ok (Some (repo, rel)) ->
      Alcotest.(check string) "matched repo id" "masc" repo.id;
      Alcotest.(check string) "empty rel at root" "" rel
    | Ok None -> Alcotest.fail "expected match at repo root"
    | Error error -> Alcotest.fail ("lookup failed: " ^ error))

let test_lookup_preserves_catalog_error () =
  with_temp_base_path (fun base_path ->
      let path = Filename.concat base_path ".masc/config/repositories.toml" in
      write_file path "repository = \"broken\"\n";
      match Repo_store.find_url_by_id ~base_path "masc" with
      | Error error ->
        Alcotest.(check bool) "catalog error preserved" true
          (String_util.contains_substring error "repository must be a table")
      | Ok _ -> Alcotest.fail "catalog error must not become a missing lookup")

let () =
  Alcotest.run "Repo_store"
    [
      ( "roundtrip",
        [
          Alcotest.test_case "missing catalog is empty" `Quick
            test_load_missing_catalog_is_empty;
          Alcotest.test_case "save and load roundtrip" `Quick test_save_and_load_roundtrip;
          Alcotest.test_case "empty catalog roundtrip" `Quick
            test_empty_catalog_roundtrip;
        ] );
      ( "add",
        [
          Alcotest.test_case "add new repo" `Quick test_add_new_repo;
          Alcotest.test_case "add duplicate fails" `Quick test_add_duplicate_fails;
          Alcotest.test_case "blank local_path fails" `Quick
            test_add_rejects_blank_local_path;
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
          Alcotest.test_case "blank local_path fails" `Quick
            test_update_rejects_blank_local_path;
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
      ( "schema",
        [
          Alcotest.test_case "rejects incomplete repository" `Quick
            test_load_rejects_incomplete_repository;
          Alcotest.test_case "rejects missing repository table" `Quick
            test_load_rejects_missing_repository_table;
          Alcotest.test_case "rejects unknown top-level field" `Quick
            test_load_rejects_unknown_top_level_field;
          Alcotest.test_case "rejects noncanonical status" `Quick
            test_load_rejects_noncanonical_status;
          Alcotest.test_case "rejects unknown field" `Quick
            test_load_rejects_unknown_field;
          Alcotest.test_case "rejects wrong field type" `Quick
            test_load_rejects_wrong_field_type;
          Alcotest.test_case "Error requires status_error" `Quick
            test_error_status_requires_message;
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
          Alcotest.test_case "skips missing origin without failing discovery" `Quick
            test_discover_skips_missing_origin_without_failing_request;
          Alcotest.test_case "shares one origin inspection budget" `Quick
            test_discover_origin_budget_is_cumulative;
          Alcotest.test_case "starts origin budget after filesystem scan" `Quick
            test_discover_origin_budget_starts_after_filesystem_scan;
          Alcotest.test_case "timeout on the last candidate is a typed failure" `Quick
            test_discover_timeout_on_last_candidate_is_typed_failure;
          Alcotest.test_case "escapes discovery warning fields" `Quick
            test_discovery_warning_escapes_untrusted_fields;
        ] );
      ( "registration",
        [
          Alcotest.test_case "register_discovered auto-adds" `Quick
            test_register_discovered_auto_adds;
          Alcotest.test_case "register_discovered includes root repo" `Quick
            test_register_discovered_includes_root_repo;
          Alcotest.test_case "register_discovered skips existing" `Quick
            test_register_discovered_skips_existing;
        ] );
      ( "reverse_lookup (RFC-0128)",
        [
          Alcotest.test_case "find_url_by_id known" `Quick test_find_url_by_id_known;
          Alcotest.test_case "find_url_by_id unknown" `Quick test_find_url_by_id_unknown;
          Alcotest.test_case "path_prefix match" `Quick test_find_repo_by_path_prefix_match;
          Alcotest.test_case "path_prefix outside" `Quick test_find_repo_by_path_prefix_outside;
          Alcotest.test_case "path_prefix sibling-safe" `Quick
            test_find_repo_by_path_prefix_sibling_not_matched;
          Alcotest.test_case "path_prefix at repo root" `Quick test_find_repo_by_path_prefix_root;
          Alcotest.test_case "catalog errors are preserved" `Quick
            test_lookup_preserves_catalog_error;
        ] );
      ( "upstream identity",
        [
          Alcotest.test_case "two records for one upstream are rejected" `Quick
            test_load_all_rejects_two_records_for_one_upstream;
          Alcotest.test_case "distinct upstreams both load" `Quick
            test_load_all_accepts_distinct_upstreams;
        ] );
    ]
