let usage () =
  prerr_endline "usage: dune exec ./bin/cascade_materialize.exe -- [path/to/cascade.json]";
  exit 2
;;

let config_path () =
  match Array.to_list Sys.argv with
  | [ _ ] -> Masc_mcp.Config_dir_resolver.cascade_path_candidate ()
  | [ _; "--help" ] | [ _; "-h" ] -> usage ()
  | [ _; path ] -> path
  | _ -> usage ()
;;

let () =
  let config_path = config_path () in
  match Masc_mcp.Cascade_toml_materializer.ensure_materialized_json ~config_path with
  | Error msg ->
    prerr_endline msg;
    exit 1
  | Ok { source; wrote_json } ->
    Printf.printf
      "source=%s source_path=%s json_path=%s wrote_json=%b\n"
      (Masc_mcp.Cascade_toml_materializer.source_kind_to_string source.kind)
      source.source_path
      source.json_path
      wrote_json
;;
