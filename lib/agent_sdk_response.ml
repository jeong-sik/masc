(** OAS response helpers.

    Repo-local code should read SDK responses through this module rather than
    reaching into provider-specific helper namespaces. *)

type api_response = Agent_sdk.Types.api_response

let text_of_response (response : api_response) =
  Agent_sdk.Types.text_of_content response.content

let model_used (response : api_response) =
  response.model

let usage (response : api_response) = response.usage
