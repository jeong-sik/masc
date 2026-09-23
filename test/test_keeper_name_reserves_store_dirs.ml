open Alcotest
open Masc

let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = sub || at (i + 1)) in
  at 0

let test_store_directory_names_are_not_keeper_names () =
  List.iter
    (fun store ->
       let dirname = Common.keeper_runtime_store_dirname store in
       match Common.keeper_runtime_store_placement store with
       | Common.Keepers_root_scoped ->
         check bool (dirname ^ " refused") false (Keeper_config.validate_name dirname);
         check bool
           (dirname ^ " refusal names the store")
           true
           (contains ~sub:("keepers/" ^ dirname) (Keeper_config.invalid_name_error dirname))
       | Common.Keeper_scoped_dated
       | Common.Keeper_scoped_versioned
       | Common.Keeper_scoped_rotated
       | Common.Workspace_scoped -> ())
    Common.keeper_runtime_stores

(* The typed name and [validate_name] answer the same question; the list is
   not empty, so the checks above are not vacuous. *)
let test_typed_name_agrees () =
  check bool "tool_usage is kept under keepers/" true
    (List.mem "tool_usage" Common.keepers_root_store_dirnames);
  List.iter
    (fun dirname ->
       check bool (dirname ^ " refused as a typed name") true
         (Result.is_error (Keeper_id.Keeper_name.of_string dirname)))
    Common.keepers_root_store_dirnames;
  check bool "ordinary typed name" true
    (Result.is_ok (Keeper_id.Keeper_name.of_string "masc-pro-builder"))

let test_case_is_ignored () =
  List.iter
    (fun dirname ->
       check bool (dirname ^ " is lowercase") true
         (String.equal dirname (String.lowercase_ascii dirname));
       let upper = String.uppercase_ascii dirname in
       check bool (upper ^ " refused: same directory on a case-insensitive disk") false
         (Keeper_config.validate_name upper))
    Common.keepers_root_store_dirnames

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK); _ } ->
    Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o755)

(* Any workspace where a keeper flushed tool usage has keepers/tool_usage/;
   the retained keeper listing must pass over it, yet still refuse an unknown
   directory whose name is not a keeper name. *)
let test_retained_listing_passes_over_store_directories () =
  let base_path = Filename.temp_dir "keeper-name-reserves" "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () ->
    let config = Workspace.default_config base_path in
    let keepers_dir = Workspace.keepers_runtime_dir config in
    mkdir_p (Filename.concat keepers_dir "alpha");
    List.iter (fun dirname -> mkdir_p (Filename.concat keepers_dir dirname))
      Common.keepers_root_store_dirnames;
    (match Keeper_meta_store.retained_keeper_names_read_only_result config with
     | Ok names -> check (list string) "only the keeper is listed" [ "alpha" ] names
     | Error detail -> fail detail);
    mkdir_p (Filename.concat keepers_dir "not a keeper!");
    match Keeper_meta_store.retained_keeper_names_read_only_result config with
    | Error _ -> ()
    | Ok names -> fail ("unknown invalid directory was accepted: " ^ String.concat "," names))

let test_ordinary_names_still_pass () =
  List.iter
    (fun name -> check bool name true (Keeper_config.validate_name name))
    [ "masc-pro-builder"; "tool-usage"; "tool_usage_2"; "trajectories" ]

let test_non_portable_names_keep_their_message () =
  check bool "slash refused" false (Keeper_config.validate_name "a/b");
  check bool "grammar message kept" false
    (contains ~sub:"runtime store" (Keeper_config.invalid_name_error "a/b"))

let () =
  run "keeper_name_reserves_store_dirs"
    [ ( "name"
      , [ test_case "store directory names are not keeper names" `Quick
            test_store_directory_names_are_not_keeper_names
        ; test_case "the typed name agrees" `Quick test_typed_name_agrees
        ; test_case "case is ignored" `Quick test_case_is_ignored
        ; test_case "retained listing passes over store directories" `Quick
            test_retained_listing_passes_over_store_directories
        ; test_case "ordinary names still pass" `Quick test_ordinary_names_still_pass
        ; test_case "non-portable names keep their message" `Quick
            test_non_portable_names_keep_their_message
        ] ) ]
