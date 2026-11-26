(** Shared completion-measurement types and explicit policy flags.

    Single owner for the measurement record shared by agent-admission
    counting ([Count_tokens_sync]) and frozen-artifact exact-output counting
    ([Exact_output_count_tokens]): both counted completions, but over
    different envelopes.  Admission counts Gemini through its own
    countTokens endpoint; the exact-output path freezes an Anthropic Messages
    artifact and therefore never counts a Gemini body as an Anthropic
    artifact.  The predicates are therefore two explicit policies, not one
    same-named flag with opposite Gemini answers. *)

type measurement_transport_stage =
  | Measurement_before_dispatch
  | Measurement_dispatch_started
  | Measurement_response_received of int

type completion_request_measurement =
  { input_count : Input_token_count.count
  ; output_token_receipt : Types.output_token_receipt
  }

type completion_request_error =
  | Input_count_failed of Input_token_count.error
  | Output_token_resolution_failed of Types.required_output_token_error
  | Invalid_completion_request of string

(** Admission policy: Anthropic, Kimi and Gemini count — Gemini via its
    countTokens endpoint.  Used by [Count_tokens_sync] and the
    [Prepared_completion_request] admission round trip. *)
let supports_admission_measurement (config : Provider_config.t) =
  match config.kind with
  | Provider_config.Anthropic | Provider_config.Kimi | Provider_config.Gemini -> true
  | Provider_config.OpenAI_compat | Provider_config.Ollama | Provider_config.Glm -> false

(** Exact-artifact policy: only Anthropic / Kimi — the frozen body is an
    Anthropic Messages envelope.  Used by [Exact_output_count_tokens] and
    [Exact_output_plan].  Gemini is excluded even though admission can count
    it, because a Gemini request is not an Anthropic artifact. *)
let supports_exact_artifact_measurement (config : Provider_config.t) =
  match config.kind with
  | Provider_config.Anthropic | Provider_config.Kimi -> true
  | Provider_config.OpenAI_compat
  | Provider_config.Ollama
  | Provider_config.Gemini
  | Provider_config.Glm ->
      false
