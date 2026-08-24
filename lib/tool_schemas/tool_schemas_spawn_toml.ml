(** The four spawn tools, read from [config/tools/masc_spawn*.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a partial spawn
    surface, so a reader of these values never has to ask whether a schema
    loaded. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let start = schema_of_name "masc_spawn"
let read = schema_of_name "masc_spawn_read"
let wait = schema_of_name "masc_spawn_wait"
let stop = schema_of_name "masc_spawn_stop"
