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

let write_mapping base_path keeper_id repo_ids =
  let path = Filename.concat base_path ".masc/config/keeper_repo_mappings.toml" in
  let entries =
    String.concat ", " (List.map (fun s -> "\"" ^ s ^ "\"") repo_ids)
  in
  let content = Printf.sprintf "[mapping.%s]\nrepositories = [%s]\n" keeper_id entries in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

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
        { keeper_id = "keeper-new"; repository_ids = [ "repo-a"; "repo-b" ] }
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
        ] );
      ( "validate_access",
        [
          Alcotest.test_case "allowed" `Quick test_validate_access_allowed;
          Alcotest.test_case "denied" `Quick test_validate_access_denied;
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
        ] );
    ]
