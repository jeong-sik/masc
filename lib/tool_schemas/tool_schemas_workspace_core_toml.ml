(** [masc_status], [masc_check] and [masc_heartbeat], read from
    [config/tools/masc_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot rather than advertising a partial workspace surface.
    Nothing here derives a value from an owner module. *)

let schema_of_name = Tool_definition_embedded.schema

let status = schema_of_name "masc_status"
let check = schema_of_name "masc_check"
let heartbeat = schema_of_name "masc_heartbeat"
