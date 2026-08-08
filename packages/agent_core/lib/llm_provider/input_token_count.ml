type protocol =
  | Anthropic_messages_count_tokens
  | Openai_responses_input_tokens
  | Gemini_count_tokens
[@@deriving show, eq]

type count =
  { input_tokens : int
  ; protocol : protocol
  ; model_id : string
  }
[@@deriving show, eq]

type error =
  | Unsupported of
      { protocol : protocol
      ; model_id : string
      }
  | Transport of Http_client.http_error
  | Invalid_response of
      { protocol : protocol
      ; model_id : string
      ; detail : string
      }

(* Field path to the provider-reported count. Anthropic count_tokens and
   Gemini countTokens report at the top level; the OpenAI Responses API only
   reports input tokens inside the response "usage" envelope. *)
let token_field_path = function
  | Anthropic_messages_count_tokens -> [ "input_tokens" ]
  | Openai_responses_input_tokens -> [ "usage"; "input_tokens" ]
  | Gemini_count_tokens -> [ "totalTokens" ]
;;

let invalid protocol model_id detail =
  Error (Invalid_response { protocol; model_id; detail })
;;

let nonnegative_int ~protocol ~model_id ~field = function
  | `Int value when value >= 0 -> Ok value
  | `Int _ -> invalid protocol model_id (Printf.sprintf "%s must be non-negative" field)
  | `Intlit _ ->
    invalid
      protocol
      model_id
      (Printf.sprintf "%s is outside the supported integer range" field)
  | json ->
    invalid
      protocol
      model_id
      (Printf.sprintf
         "%s must be an integer (got %s)"
         field
         (Json_util.json_type_name json))
;;

let decode_response ~protocol ~model_id body =
  match Json_util.decode_json_with Fun.id body with
  | Error detail -> invalid protocol model_id detail
  | Ok json ->
    let rec extract json consumed = function
      | [] ->
        Result.map
          (fun input_tokens -> { input_tokens; protocol; model_id })
          (nonnegative_int ~protocol ~model_id ~field:consumed json)
      | key :: rest ->
        (match json with
         | `Assoc fields ->
           let consumed = if consumed = "" then key else consumed ^ "." ^ key in
           (match List.assoc_opt key fields with
            | None ->
              invalid
                protocol
                model_id
                (Printf.sprintf "missing required field %s" consumed)
            | Some next -> extract next consumed rest)
         | json ->
           invalid
             protocol
             model_id
             (Printf.sprintf
                "%s must be an object (got %s)"
                (if consumed = "" then "input-token count response" else consumed)
                (Json_util.json_type_name json)))
    in
    extract json "" (token_field_path protocol)
;;

let decode_transport_result ~protocol ~model_id = function
  | Error error -> Error (Transport error)
  | Ok body -> decode_response ~protocol ~model_id body
;;
