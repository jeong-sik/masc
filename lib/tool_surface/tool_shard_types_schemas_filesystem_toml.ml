(** The filesystem tools MCP clients receive, read from
    [config/tools/tool_*.toml] and [config/tools/keeper_ide_annotate.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial filesystem surface.

    These are not the model's Read / Edit / Write. Those are separate tools
    with separate schemas, and their declarations carried these names until the
    files were renamed to what they publish -- which is what freed the names
    here. [test_filesystem_shard_toml_parity] pins all four against what the
    list published before the move. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let read_file = schema_of_name "tool_read_file"
let edit_file = schema_of_name "tool_edit_file"
let write_file = schema_of_name "tool_write_file"
let ide_annotate = schema_of_name "keeper_ide_annotate"
