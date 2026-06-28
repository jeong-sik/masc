type t =
  | Personas_root
  | Personas_dirs_resolve
  | Toml_skip
  | Toml_fallback
  | Materializable_check
  | Load_persona_extended
  | Agent_md_read
  | List_persona_summaries

let to_label = function
  | Personas_root -> "personas_root"
  | Personas_dirs_resolve -> "personas_dirs_resolve"
  | Toml_skip -> "toml_skip"
  | Toml_fallback -> "toml_fallback"
  | Materializable_check -> "materializable_check"
  | Load_persona_extended -> "load_persona_extended"
  | Agent_md_read -> "agent_md_read"
  | List_persona_summaries -> "list_persona_summaries"
;;
