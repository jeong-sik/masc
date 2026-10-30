open Alcotest
open Masc
open Masc.Keeper_types_profile

let meta profile =
  match Masc_test_deps.meta_of_json_fixture
          (`Assoc [ "name", `String "observed-keeper"
                  ; "trace_id", `String "trace-observed-keeper" ]) with
  | Ok meta -> { meta with sandbox_profile = profile; microvm_backend = None }
  | Error error -> fail error
;;

let observe profile ?containers_override () =
  let base_path = Filename.temp_dir "masc-sandbox-observation-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
      Keeper_sandbox_control.live_status_json
        ~include_preflight:false ~include_repository_checkouts:false
        ?containers_override ~config:(Workspace.default_config base_path)
        ~meta:(meta profile) ~timeout_sec:1. ~verbose:false ())
;;

let field key = Yojson.Safe.Util.member key

let test_failed_inventory_is_unknown () =
  let json = observe Docker ~containers_override:(Error "inventory unavailable") () in
  check bool "failed Docker inventory cannot establish a mode" true
    (field "effective_mode" json = `Null);
  check string "original failure survives" "inventory unavailable"
    (field "container_error" json |> Yojson.Safe.Util.to_string)
;;

let test_unresolved_microvm_is_unknown () =
  let json = observe Micro_vm () in
  check bool "unresolved microVM backend is not a stopped guest" true
    (field "effective_mode" json = `Null);
  check bool "the failed inventory remains visible" true
    (field "container_error" json <> `Null)
;;

let test_successful_inventory_keeps_mode () =
  let json = observe Docker ~containers_override:(Ok []) () in
  check bool "successful empty inventory has no error" true
    (field "container_error" json = `Null);
  check bool "successful inventory retains its effective mode" true
    (field "effective_mode" json <> `Null)
;;

let () =
  run "keeper_sandbox_observation"
    [ "inventory", [ test_case "failed inventory is unknown" `Quick test_failed_inventory_is_unknown
                   ; test_case "unresolved microVM is unknown" `Quick test_unresolved_microvm_is_unknown
                   ; test_case "successful inventory keeps mode" `Quick test_successful_inventory_keeps_mode ] ]
;;
