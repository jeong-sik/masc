(** [masc_status], [masc_check] and [masc_heartbeat], read from
    [config/tools/masc_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot rather than advertising a partial workspace surface.
    Nothing here derives a value from an owner module. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let status = schema_of_name "masc_status"
let check = schema_of_name "masc_check"
let heartbeat = schema_of_name "masc_heartbeat"
