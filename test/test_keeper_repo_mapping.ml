(** Persistence tests for advisory keeper repository preferences. *)

let path_exists_no_follow path =
  match Unix.lstat path with
  | _ -> true
  | exception Unix.Unix_error _ -> false
;;

let is_directory_no_follow path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> true
  | _ -> false
  | exception Unix.Unix_error _ -> false
;;

let rec remove_tree path =
  if path_exists_no_follow path
  then if is_directory_no_follow path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base_path test =
  let base_path = Filename.temp_file "keeper-repo-preference" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> test base_path)
;;

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path
  then ()
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let write_mapping_raw base_path content =
  let path = Keeper_repo_mapping.mappings_toml_path base_path in
  ensure_dir (Filename.dirname path);
  let output = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output content)
;;

let save_mapping base_path keeper_id repository_ids =
  let mapping =
    Repo_manager_types.make_keeper_repo_mapping ~keeper_id ~repository_ids
  in
  match Keeper_repo_mapping.save_mapping ~base_path mapping with
  | Ok () -> ()
  | Error message -> Alcotest.fail message
;;

let load_mapping base_path keeper_id =
  match Keeper_repo_mapping.load_all ~base_path with
  | Error message -> Alcotest.fail message
  | Ok mappings ->
    (match
       List.find_opt
         (fun (mapping : Repo_manager_types.keeper_repo_mapping) ->
           String.equal mapping.keeper_id keeper_id)
         mappings
     with
     | Some mapping -> mapping
     | None -> Alcotest.fail ("missing mapping for " ^ keeper_id))
;;

let test_missing_file_is_empty () =
  with_temp_base_path (fun base_path ->
    Alcotest.(check int)
      "no preferences"
      0
      (Keeper_repo_mapping.load_all ~base_path |> Result.get_ok |> List.length))
;;

let test_malformed_top_level_mapping_is_explicit () =
  with_temp_base_path (fun base_path ->
    write_mapping_raw base_path "mapping = 42\n";
    match Keeper_repo_mapping.load_all ~base_path with
    | Ok _ -> Alcotest.fail "malformed mapping unexpectedly loaded"
    | Error message ->
      Alcotest.(check string)
        "typed boundary error"
        "mapping field must be a table"
        message)
;;

let test_wildcard_scope_is_parsed_at_boundary () =
  with_temp_base_path (fun base_path ->
    write_mapping_raw base_path "[mapping.executor]\nrepositories = [\"*\"]\n";
    let mapping = load_mapping base_path "executor" in
    match mapping.repository_scope with
    | Repo_manager_types.All_repositories -> ()
    | Repo_manager_types.Selected_repositories _ ->
      Alcotest.fail "wildcard scope was not parsed")
;;

let test_save_creates_directory_and_replaces_same_keeper () =
  with_temp_base_path (fun base_path ->
    save_mapping base_path "executor" [ "masc"; "oas" ];
    save_mapping base_path "reviewer" [ "docs" ];
    save_mapping base_path "executor" [ "masc" ];
    let mappings = Keeper_repo_mapping.load_all ~base_path |> Result.get_ok in
    Alcotest.(check int) "one row per keeper" 2 (List.length mappings);
    let executor = load_mapping base_path "executor" in
    Alcotest.(check (list string))
      "latest preference"
      [ "masc" ]
      executor.repository_ids)
;;

let () =
  Alcotest.run
    "Keeper_repo_mapping"
    [ ( "persistence"
      , [ Alcotest.test_case "missing file" `Quick test_missing_file_is_empty
        ; Alcotest.test_case
            "malformed top-level mapping"
            `Quick
            test_malformed_top_level_mapping_is_explicit
        ; Alcotest.test_case
            "wildcard scope"
            `Quick
            test_wildcard_scope_is_parsed_at_boundary
        ; Alcotest.test_case
            "save and replace"
            `Quick
            test_save_creates_directory_and_replaces_same_keeper
        ] )
    ]
;;
