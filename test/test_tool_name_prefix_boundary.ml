(** Catalog files must resolve to their declared tool identities. Naming style
    does not decide whether a tool is valid or which authority it has. *)
open Alcotest

let tools_dir =
  let root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when Sys.file_exists root -> root
    | Some _ | None -> Sys.getcwd ()
  in
  Filename.concat root "config/tools"

let test_declared_name_matches_the_file () =
  let files =
    Sys.readdir tools_dir |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".toml")
  in
  check bool "catalog is not empty" true (files <> []);
  List.iter (fun file ->
    let path = Filename.concat tools_dir file in
    let toml = match Otoml.Parser.from_file_result path with
      | Ok toml -> toml
      | Error message -> failf "%s: %s" file message
    in
    match Otoml.find_opt toml Otoml.get_string [ "name" ] with
    | Some name -> check string file (Filename.remove_extension file) name
    | None -> failf "%s has no declared tool name" file
  ) files

let () =
  run "Tool catalog identity"
    [ "catalog", [ test_case "declared name resolves from its file" `Quick
        test_declared_name_matches_the_file ] ]
