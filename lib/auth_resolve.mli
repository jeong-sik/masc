(** Typed bearer-token resolution for cascade dispatch.

    Replaces the silent fall-back chain inside
    [oas_worker_exec_transport] that hid empty-Bearer-401 cascades
    behind generic HTTP error logs.

    Step 1a of the bloodflow restoration plan introduces only the
    type definitions, the resolve function, and the trace emitter.
    Caller-side adoption (rewriting [oas_worker_exec_transport.ml:399]
    and friends) is intentionally deferred to Step 1b so this module
    can land additively. *)

type token_source =
  | Internal_keeper_token
      (** [.masc/auth/internal_keeper.token.hash] backed; raw token
          carried by [MASC_INTERNAL_MCP_TOKEN] env at runtime. *)
  | Internal_keeper_env
      (** [MASC_INTERNAL_MCP_TOKEN] resolved without the hash file
          present; legacy / startup-bootstrap path. *)
  | Mcp_bearer_env
      (** [MASC_MCP_TOKEN] env, last-resort. *)
  | Per_keeper_token_file
      (** [<base_path>/.masc/auth/<agent_name>.token] raw token; used as
          a fallback when [MASC_MCP_TOKEN] is unset (e.g. CLI subprocesses
          like codex_cli/gemini_cli/kimi_cli that callback into masc-mcp
          but do not inherit the parent process env). Phase A F1. *)
  | Provider_api_key_env of { var_name : string }
      (** Provider-specific HTTPS API key, e.g.
          [ANTHROPIC_API_KEY] / [KIMI_API_KEY] / [ZHIPU_API_KEY]. *)

type token = { raw : string; source : token_source }

type auth_error =
  | Token_hash_missing of { path : string }
  | Token_hash_mismatch of {
      keeper_id : string;
      presented_source : token_source;
    }
  | Credential_file_missing of { path : string }
  | Api_key_env_unset of { var_name : string }
  | Bound_actor_provider_mismatch of {
      provider_kind : Llm_provider.Provider_config.provider_kind;
    }

val pp_auth_error : Format.formatter -> auth_error -> unit
val show_auth_error : auth_error -> string
val token_source_label : token_source -> string

val resolve :
  base_path:string ->
  keeper_id:string option ->
  provider_kind:Llm_provider.Provider_config.provider_kind ->
  policy_requires_runtime_mcp:bool ->
  (token, auth_error) result
(** Resolve a token for a single dispatch.

    Resolution order:
    1. If [keeper_id = Some k] AND [policy_requires_runtime_mcp]: try
       [internal_keeper.token.hash] presence; pull the raw token from
       [MASC_INTERNAL_MCP_TOKEN] (preferred) or [MASC_MCP_TOKEN].
       Hash-file absence yields [Token_hash_missing].
    2. If [provider_kind] is an HTTP variant with a default api-key
       env, resolve from that env.  Missing env yields
       [Api_key_env_unset].
    3. If [provider_kind] is [Codex_cli] AND
       [policy_requires_runtime_mcp = false] (a degenerate combo we
       still classify), yield [Bound_actor_provider_mismatch].
    4. CLI providers (Claude_code/Gemini_cli/Kimi_cli) without a
       runtime-mcp policy fall through to [MASC_MCP_TOKEN] env. *)

val emit_resolution_trace :
  cascade:string ->
  keeper_id:string option ->
  provider_label:string ->
  outcome:(token, auth_error) result ->
  unit
(** Emit a structured trace event for a resolution attempt — both
    success and failure are surfaced, so cascade traces show
    "fell back from internal_keeper_token (Token_hash_missing) to
    Mcp_bearer_env (resolved)" before any HTTP 401 occurs. *)
