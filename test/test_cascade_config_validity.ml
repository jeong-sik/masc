(** RFC-0058 cascade config SSOT validity gate.

    CI calls this test directly to keep [config/cascade.toml] as the checked-in
    authoring source and to prevent the retired [config/cascade.json] from
    reappearing as a second source of truth. *)

open Alcotest

module Adapter = Masc_mcp.Cascade_declarative_adapter
module Parser = Cascade_declarative_parser
module Validator = Cascade_declarative_validator

let config_path name =
  Filename.concat
    (Filename.concat (Masc_test_deps.find_project_root ()) "config")
    name
;;

let parse_errors_to_string errs =
  errs
  |> List.map (fun (err : Parser.parse_error) ->
    Printf.sprintf "%s: %s" err.path err.message)
  |> String.concat "; "
;;

let validation_errors_to_string errs =
  errs
  |> List.map (fun (err : Validator.validation_error) ->
    Printf.sprintf "%s %s: %s" err.rule err.path err.message)
  |> String.concat "; "
;;

let adapter_errors_to_string errs =
  errs |> List.map Adapter.show_adapter_error |> String.concat "; "
;;

let load_checked_in_cascade_toml () =
  let path = config_path "cascade.toml" in
  match Parser.parse_file path with
  | Ok cfg -> cfg
  | Error errs ->
    failf "failed to parse %s: %s" path (parse_errors_to_string errs)
;;

let test_cascade_toml_validates () =
  let cfg = load_checked_in_cascade_toml () in
  let validation_errors = Validator.validate cfg in
  check
    string
    "validator errors"
    ""
    (validation_errors_to_string validation_errors);
  let (catalog : Adapter.adapted_catalog) = Adapter.adapt_config cfg in
  check string "adapter errors" "" (adapter_errors_to_string catalog.errors);
  check bool "profiles generated" true (List.length catalog.profiles > 0);
  check bool "routes generated" true (List.length catalog.routes > 0)
;;

let test_cascade_json_absent () =
  check bool "config/cascade.json absent" false (Sys.file_exists (config_path "cascade.json"))
;;

let () =
  run
    "cascade config validity"
    [ ( "checked-in seed"
      , [ test_case "cascade.toml parses, validates, and adapts" `Quick test_cascade_toml_validates
        ; test_case "cascade.json is not a checked-in source" `Quick test_cascade_json_absent
        ] )
    ]
;;
