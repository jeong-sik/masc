(** OAS response helpers.

    Repo-local code should read SDK responses through this module rather than
    reaching into provider-specific helper namespaces. *)

type api_response = Agent_sdk.Types.api_response

let text_of_response (response : api_response) =
  Agent_sdk.Types.visible_text_of_response response

let visible_text_response (response : api_response) : api_response =
  let text = text_of_response response in
  { response with
    content = if String.trim text = "" then [] else [ Agent_sdk.Types.Text text ]
  }
;;

let structured_json_of_response ?(schema_name = "masc_structured_response") response =
  let schema : Yojson.Safe.t Agent_sdk.Structured.schema =
    { name = schema_name
    ; description = "MASC structured JSON response"
    ; params = []
    ; parse = (fun json -> Ok json)
    }
  in
  Agent_sdk.Structured.schema_extractor schema (visible_text_response response)
;;

let usage (response : api_response) = response.usage
