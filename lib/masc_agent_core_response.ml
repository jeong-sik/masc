(** OAS response helpers.

    Repo-local code should read SDK responses through this module rather than
    reaching into provider-specific helper namespaces. *)

type api_response = Masc_agent_core.Types.api_response

let text_of_response (response : api_response) =
  Masc_agent_core.Types.visible_text_of_response response

let usage (response : api_response) = response.usage
