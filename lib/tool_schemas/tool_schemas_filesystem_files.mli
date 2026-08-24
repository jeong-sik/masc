(** The four embedded filesystem tool declarations. The implementation decodes
    [config/tools/tool_{read,edit,write,search}_file*.toml] at module
    initialization and refuses the boot on a missing or undecodable
    declaration — this interface only exposes the four decoded schemas that
    [Keeper_tool_descriptor] and friends consume. *)

val read_file : Masc_domain.tool_schema
val edit_file : Masc_domain.tool_schema
val write_file : Masc_domain.tool_schema
val search_files : Masc_domain.tool_schema
