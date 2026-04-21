(** OAS response helpers.

    Repo-local code should read SDK responses through this module rather than
    reaching into provider-specific helper namespaces. *)

type api_response = Oas.Types.api_response

let text_of_response (response : api_response) =
  Oas.Types.text_of_content response.content

let model_used (response : api_response) =
  response.model

let usage_or_zero (response : api_response) =
  match response.usage with
  | Some usage -> usage
  | None ->
      {
        Oas.Types.input_tokens = 0;
        output_tokens = 0;
        cache_creation_input_tokens = 0;
        cache_read_input_tokens = 0;
        cost_usd = None;
      }
