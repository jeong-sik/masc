(** Lossless provider-input preflight over canonical Keeper history.

    Keeper checkpoints and the provider-bound message list retain the same
    complete transcript. This projection applies only the pre-existing
    artifact hydration, verifies that it changed no structural or semantic
    position, then measures OAS's provider-specific final serialization.

    When the selected runtime declares [max_request_body_bytes], an oversized
    request is deliberately returned intact. OAS's authoritative final
    admission rejects it with typed [Request_body_too_large] before HTTP;
    MASC's existing typed capacity lane then compacts the canonical checkpoint
    and requeues the exact durable source. No recent-history truncation or
    bytes-per-token estimate is used. *)

type observation =
  { limit_bytes : int
  ; stream : bool
  ; canonical_history_messages : int
  ; current_run_messages : int
  ; body_bytes : int
  ; body_sha256 : string
  ; fits : bool
  }

val create :
  canonical_prefix:Agent_sdk.Types.message list ->
  provider_config:Llm_provider.Provider_config.t ->
  tools:Agent_sdk.Tool.t list ->
  stream:bool ->
  base_projection:
    (Agent_sdk.Types.message list -> Agent_sdk.Types.message list) ->
  ?observe:(observation -> unit) ->
  unit ->
  Agent_sdk.Agent.model_input_projection
(** [create] returns an OAS model-input projection tied to one resolved runtime
    candidate and one exact API strategy.

    [base_projection] may replace only a ToolResult's opaque payload while
    preserving every message position, role, protocol identity, and all other
    content. Keeper's artifact hydrator satisfies that contract. The preflight
    fails closed if the canonical prefix is absent or the base projection
    violates this invariant. *)
