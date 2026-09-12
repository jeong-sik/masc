(** [masc_web_search] and [masc_web_fetch] declarations, moved to
    [config/tools/masc_web_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot. [Tool_schemas_misc] is the only consumer. *)

val web_search : Masc_domain.tool_schema
val web_fetch : Masc_domain.tool_schema
val browser_tabs : Masc_domain.tool_schema
val browser_read : Masc_domain.tool_schema
val browser_session : Masc_domain.tool_schema
val browser_goto : Masc_domain.tool_schema
val browser_act : Masc_domain.tool_schema
val browser_interact : Masc_domain.tool_schema


(** MSX lane tools (RFC-0439 §3.5), read from config/tools/masc_msx_*.toml. *)
val msx_load : Masc_domain.tool_schema
val msx_eject : Masc_domain.tool_schema
val msx_save : Masc_domain.tool_schema
val msx_restore : Masc_domain.tool_schema
val msx_change_disk : Masc_domain.tool_schema
val msx_screen : Masc_domain.tool_schema
val msx_press : Masc_domain.tool_schema
val msx_step : Masc_domain.tool_schema
val msx_step_until_change : Masc_domain.tool_schema
val msx_peek : Masc_domain.tool_schema
val msx_ram_diff : Masc_domain.tool_schema

(** Optional Lane Add-on observation and lifecycle tools. *)
val lane_attach : Masc_domain.tool_schema
val lane_declaration_read : Masc_domain.tool_schema
val lane_declaration_save : Masc_domain.tool_schema
val lane_inspect : Masc_domain.tool_schema
val lane_observe : Masc_domain.tool_schema
val lane_slice : Masc_domain.tool_schema
val lane_detach : Masc_domain.tool_schema
val lane_evidence : Masc_domain.tool_schema

val lane_act : Masc_domain.tool_schema
val lane_action_status : Masc_domain.tool_schema
