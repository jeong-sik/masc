(** The six voice tools, read from [config/tools/keeper_voice_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial voice surface, so a reader of these values never has to ask whether
    a schema loaded.

    Nothing here derives a value from an owner module, so the whole list moved.
    [test_voice_tool_toml_parity] pins all six against what the list published
    before the move. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let speak = schema_of_name "keeper_voice_speak"
let listen = schema_of_name "keeper_voice_listen"
let agent = schema_of_name "keeper_voice_agent"
let sessions = schema_of_name "keeper_voice_sessions"
let session_start = schema_of_name "keeper_voice_session_start"
let session_end = schema_of_name "keeper_voice_session_end"
