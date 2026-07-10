(** Typed, secret-safe bearer resolution for runtime dispatch.

    Runtime-MCP callers receive a raw bearer only after the workspace
    credential SSOT verifies token ownership and expiry. Resolution failure is
    explicit and traced; no caller may downgrade it to a headerless protected
    policy. *)

type token_source =
  | Mcp_bearer_env
      (** [MASC_TOKEN] env after {!Auth.resolve_agent_from_token} verified that
          it belongs to one current, non-expired workspace credential. *)
  | Per_keeper_token_file
      (** [<base_path>/.masc/auth/<agent_name>.token] after
          {!Auth.verify_token} verified the exact agent and expiry. *)
  | Provider_api_key_env of { var_name : string }
      (** Provider-specific HTTPS API key, e.g.
          [ANTHROPIC_API_KEY] / [KIMI_API_KEY] / [ZHIPU_API_KEY]. *)

type token = {
  raw : string;
  source : token_source;
  verified_agent_name : string option;
}
(** A raw MASC token may leave this module only after credential verification.
    [verified_agent_name = None] is reserved for provider API keys; every MASC
    runtime-MCP bearer carries [Some owner]. *)

type verification_failure =
  | Invalid_token
  | Token_expired of { agent_name : string }
  | Actor_mismatch
  | Unauthorized
  | Forbidden
  | Credential_store_failure
  | Unexpected_auth_failure

type auth_error =
  | Raw_token_unavailable of { agent_name : string }
  | Credential_verification_failed of {
      agent_name : string;
      presented_source : token_source;
      failure : verification_failure;
    }
  | Credential_owner_mismatch of {
      expected_agent_name : string;
      actual_agent_name : string;
      presented_source : token_source;
    }
  | Unbound_token_verification_failed of {
      presented_source : token_source;
      failure : verification_failure;
    }
  | Api_key_env_unset of { var_name : string }
  | Bound_actor_provider_mismatch of {
      provider_kind : Llm_provider.Provider_config.provider_kind;
    }

val pp_auth_error : Format.formatter -> auth_error -> unit
val show_auth_error : auth_error -> string
val token_source_label : token_source -> string
val verification_failure_label : verification_failure -> string

val resolve_runtime_mcp :
  base_path:string ->
  agent_name:string option ->
  (token, auth_error) result
(** Resolve the only bearer accepted by the protected runtime-MCP lane.

    - [Some agent_name] reads the exact per-agent raw-token file, verifies it
      with {!Auth.verify_token}, rejects expiry, and rejects alias/owner drift.
    - [None] reads [MASC_TOKEN] and verifies it with
      {!Auth.resolve_agent_from_token}.

    No shared internal-keeper token participates in this boundary. *)

val resolve :
  base_path:string ->
  agent_name:string option ->
  provider_kind:Llm_provider.Provider_config.provider_kind ->
  policy_requires_runtime_mcp:bool ->
  (token, auth_error) result
(** Resolve a token for a single dispatch.

    Resolution order:
    1. If [policy_requires_runtime_mcp], delegate to
       {!resolve_runtime_mcp}; [agent_name] is the exact credential owner.
    2. If [provider_kind] is an HTTP variant with a default api-key
       env, resolve from that env.  Missing env yields
       [Api_key_env_unset].
    3. If [provider_kind] is [Cli_tool_a] AND
       [policy_requires_runtime_mcp = false] (a degenerate combo we
       still classify), yield [Bound_actor_provider_mismatch].
    4. CLI providers without a runtime-mcp policy may resolve [MASC_TOKEN],
       but it is still verified against the workspace credential store. *)

val emit_resolution_trace :
  runtime:string ->
  keeper_id:string option ->
  provider_label:string ->
  outcome:(token, auth_error) result ->
  unit
(** Emit a structured trace event for a resolution attempt. Raw secrets are
    never formatted; success reports only source and verified owner, while
    failure reports a typed reason. *)
