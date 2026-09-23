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
        ; test_case "ordinary names still pass" `Quick test_ordinary_names_still_pass
        ; test_case "non-portable names keep their message" `Quick
            test_non_portable_names_keep_their_message
        ] ) ]
