(** Llm_client — Vendor-agnostic LLM client for the Perpetual Agent Runtime.

    Unified interface for calling any LLM provider. All providers are
    normalized to an internal message format and results are parsed into
    structured completion_response records.

    This module re-exports {!Llm_types} and {!Llm_orchestration} so that
    existing callers can continue using [Llm_client.X] without changes.

    @since 2.61.0 *)

(* Re-export sub-modules for backward compatibility *)
include Llm_types
include Llm_orchestration

(* ================================================================ *)
(* OAS Type Adapters                                                *)
(* ================================================================ *)

let to_oas_provider (spec : model_spec) : Agent_sdk.Provider.config option =
  match spec.provider with
  | Claude ->
    Some {
      Agent_sdk.Provider.provider = Agent_sdk.Provider.Anthropic;
      model_id = spec.model_id;
      api_key_env = Option.value ~default:"ANTHROPIC_API_KEY" spec.api_key_env;
    }
  | Llama ->
    Some {
      Agent_sdk.Provider.provider =
        Agent_sdk.Provider.Local { base_url = spec.api_url };
      model_id = spec.model_id;
      api_key_env = "";
    }
  | Glm_cloud | OpenAI | OpenRouter ->
    Some {
      Agent_sdk.Provider.provider =
        Agent_sdk.Provider.OpenAICompat {
          base_url = spec.api_url;
          auth_header = None;
          path = "/v1/chat/completions";
          static_token = None;
        };
      model_id = spec.model_id;
      api_key_env = Option.value ~default:"" spec.api_key_env;
    }
  | Gemini ->
    Some {
      Agent_sdk.Provider.provider =
        Agent_sdk.Provider.OpenAICompat {
          base_url = spec.api_url;
          auth_header = None;
          path = "/v1beta/chat/completions";
          static_token = None;
        };
      model_id = spec.model_id;
      api_key_env = Option.value ~default:"GEMINI_API_KEY" spec.api_key_env;
    }
  | Custom _ -> None

(** Convert MASC message to OAS message.
    After v0.48 type convergence, this is a thin projection (drop name/tool_call_id).
    System messages are still dropped — they belong in Checkpoint.system_prompt. *)
let to_oas_message (m : message) : Agent_sdk.Types.message option =
  match m.role with
  | System -> None
  | _ -> Some { Agent_sdk.Types.role = m.role; content = m.content }

(** Convert OAS message to MASC message. Near-identity after type convergence. *)
let of_oas_message (m : Agent_sdk.Types.message) : message =
  { role = m.role; content = m.content; name = None; tool_call_id = None }

let of_oas_usage (u : Agent_sdk.Types.api_usage) : token_usage =
  {
    input_tokens = u.input_tokens;
    output_tokens = u.output_tokens;
    total_tokens = u.input_tokens + u.output_tokens;
    cache_creation_input_tokens = u.cache_creation_input_tokens;
    cache_read_input_tokens = u.cache_read_input_tokens;
  }

let to_oas_usage (u : token_usage) : Agent_sdk.Types.api_usage =
  {
    Agent_sdk.Types.input_tokens = u.input_tokens;
    output_tokens = u.output_tokens;
    cache_creation_input_tokens = u.cache_creation_input_tokens;
    cache_read_input_tokens = u.cache_read_input_tokens;
  }
