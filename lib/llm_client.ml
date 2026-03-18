(** Llm_client — OAS type adapters.

    After the Llm_client re-export removal, this module contains only
    conversion functions between MASC {!Llm_types} and OAS {!Agent_sdk} types.

    @since 2.61.0
    @since 2.114.0 — re-export removed, callers use Llm_types/Llm_orchestration directly *)

open Llm_types

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
  | Custom _ ->
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

(** Convert MASC message to OAS message.
    After v0.48 type convergence, this is a thin projection (drop name/tool_call_id).
    System messages are still dropped — they belong in Checkpoint.system_prompt. *)
let to_oas_message (m : message) : Agent_sdk.Types.message option =
  match m.role with
  | System -> None
  | _ -> Some m

(** Convert OAS message to MASC message. Near-identity after type convergence. *)
let of_oas_message (m : Agent_sdk.Types.message) : message =
  m

(** Identity after type unification. *)
let of_oas_usage (u : Agent_sdk.Types.api_usage) : token_usage = u
let to_oas_usage (u : token_usage) : Agent_sdk.Types.api_usage = u
