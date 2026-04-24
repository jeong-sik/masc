(* #10049: auto-construct Claude Code / Kimi CLI MCP config JSON when
   OAS_CLAUDE_MCP_CONFIG env is unset. Gated behind
   MASC_AUTO_CONSTRUCT_CLAUDE_MCP (default false). *)

val feature_flag_env : string

val feature_enabled : unit -> bool

val build_json : url:string -> bearer_token:string -> string

val try_construct_for_keeper :
  base_path:string -> agent_name:string -> string option
(** Returns [Some json] if the feature flag is on AND the token file
    exists, non-empty, and host/port are resolvable. [None] otherwise;
    the caller falls through to the existing behaviour unchanged. *)
