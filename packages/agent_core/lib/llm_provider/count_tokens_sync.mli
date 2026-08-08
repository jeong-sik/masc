(** Synchronous provider-native input-token count transport.

    This module owns endpoint selection, request construction dispatch, and
    transport execution for input-token counting — the pieces that
    {!Input_token_count} deliberately keeps outside its decoding boundary.

    @stability Internal *)

(** Endpoint for an Anthropic-compatible Messages count-tokens call: inserts
    [/count_tokens] after the configured request path, preserving any query
    string carried by custom or proxy configurations. *)
val count_tokens_url : Provider_config.t -> string

(** Count one Anthropic-compatible Messages input through the provider's
    native [/v1/messages/count_tokens] endpoint.

    The request reuses {!Backend_anthropic}'s provider-specific completion
    input projection. Anthropic and Kimi configs are supported; other configs
    fail with [Unsupported] before any I/O.

    The call is bounded only when [timeout_s] is explicitly supplied;
    enforcing it also requires [clock], mirroring {!Http_client.post_sync}. *)
val count_anthropic
  :  ?connection_cache:Http_client.cache
  -> ?clock:_ Eio.Time.clock
  -> ?timeout_s:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> (Input_token_count.count, Input_token_count.error) result

(** Exact provider-owned measurement of one fully prepared completion request.

    The caller supplies the immutable {!Llm_transport.completion_request} that
    reached its transport boundary, after Agent turn hooks, tool projection,
    and caller-owned message projection. The input count uses the provider's
    native count endpoint. The output receipt is resolved from the same config.

    This is a lower-level transport-adapter primitive. Application callers
    must not reconstruct a completion request to call it: final Agent-level
    fit admission must measure the same opaque prepared request that it later
    dispatches. This function neither dispatches nor returns that artifact, so
    its receipt alone does not prove a later dispatch reused the measured
    request value.

    Unsupported provider protocols fail before I/O. No character estimate,
    context-window fallback, fit policy, retry, or truncation is performed. *)
type completion_request_measurement = private
  { input_count : Input_token_count.count
  ; output_token_receipt : Types.output_token_receipt
  }

type completion_request_error =
  | Input_count_failed of Input_token_count.error
  | Output_token_resolution_failed of Types.required_output_token_error
  | Invalid_completion_request of string

(** Whether OAS has an exact provider-native measurement adapter for this
    request configuration. This is the support SSOT used by both measurement
    dispatch and Agent admission routing. *)
val supports_completion_request_measurement : Provider_config.t -> bool

val measure_completion_request
  :  ?connection_cache:Http_client.cache
  -> ?clock:_ Eio.Time.clock
  -> ?timeout_s:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> Llm_transport.completion_request
  -> (completion_request_measurement, completion_request_error) result
