(** See [tool_definition_embedded.mli]. *)

let path name = "tools/" ^ name ^ ".toml"

let find name =
  let rel = path name in
  match Embedded_config.read rel with
  | None -> Error (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents -> Tool_definition_toml.load ~name ~contents
;;

let load name =
  match find name with
  | Ok loaded -> loaded
  | Error message -> failwith message
;;

let schema name = (load name).Tool_definition_toml.schema
