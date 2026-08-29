(** WebMCP consumer tool schemas (RFC-webmcp-keeper-consumption Lane B).
    Definitions live in config/tools/keeper_webmcp_{list,call}.toml. *)

val list_schema : Masc_domain.tool_schema
val call_schema : Masc_domain.tool_schema
val schemas : Masc_domain.tool_schema list
