(** The filesystem tools MCP clients receive, read from
    [config/tools/tool_*.toml] and [config/tools/keeper_ide_annotate.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial filesystem surface.

    These are not the model's Read / Edit / Write. Those are separate tools
    with separate schemas, and their declarations carried these names until the
    files were renamed to what they publish -- which is what freed the names
    here. [test_filesystem_shard_toml_parity] keeps the publication order;
    the descriptions and schemas it also pinned were copies of these
    values. *)

let schema_of_name = Tool_definition_embedded.schema

let read_file = schema_of_name "tool_read_file"
let edit_file = schema_of_name "tool_edit_file"
let write_file = schema_of_name "tool_write_file"
let ide_annotate = schema_of_name "keeper_ide_annotate"
let search_files = schema_of_name "tool_search_files"
