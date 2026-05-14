(* #10049: auto-construct Claude Code / Kimi CLI MCP config JSON when
   OAS_CLAUDE_MCP_CONFIG env is unset. Gated behind
   MASC_AUTO_CONSTRUCT_CLAUDE_MCP (default true since #10059 validation;
   set to "false" to opt out). *)

val feature_flag_env : string

val feature_enabled : unit -> bool

val build_json : url:string -> bearer_token:string -> string

val try_construct_for_keeper :
  base_path:string -> agent_name:string -> string option
(** Returns [Some json] if the feature flag is on AND the token file
    exists, non-empty, and host/port are resolvable. [None] otherwise;
    the caller falls through to the existing behaviour unchanged. *)

val effective_for_keeper :
  base_path:string -> agent_name:string -> configured:string option -> string option
(** Explicit config wins; otherwise attempts {!try_construct_for_keeper}. *)

val missing_catalog_warning_required_for_effective :
  requires_runtime_mcp_header_sync:bool ->
  effective_claude_mcp_config:string option ->
  bool
(** [true] only when CLI runtime MCP header sync is needed and the effective
    config is still absent. *)
