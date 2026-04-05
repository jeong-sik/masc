open Alcotest

module KTP = Masc_mcp.Keeper_types_profile

(** Validate that every .toml file in config/keepers/ parses successfully
    with the OCaml TOML parser.  This catches syntax that is valid standard
    TOML but unsupported by our minimal parser (e.g. multi-line arrays before
    the fix).  Runs as part of [dune test], so CI will fail before deploy. *)

let test_all_keeper_tomls_parse () =
  let config_dir = "config/keepers" in
  if not (Sys.file_exists config_dir && Sys.is_directory config_dir) then
    (* Not running from project root -- skip gracefully. *)
    ()
  else
    let files =
      Sys.readdir config_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".toml")
      |> List.sort String.compare
    in
    check bool "at least one toml file" true (List.length files > 0);
    List.iter (fun f ->
      let path = Filename.concat config_dir f in
      match KTP.load_keeper_toml path with
      | Ok _ -> ()
      | Error e ->
        fail (Printf.sprintf "%s: %s" f e)
    ) files

let () =
  run "Keeper TOML Config Validation"
    [
      ( "config/keepers",
        [
          test_case "all toml files parse" `Quick test_all_keeper_tomls_parse;
        ] );
    ]
