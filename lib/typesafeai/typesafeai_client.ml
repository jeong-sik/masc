let ( let* ) = Result.bind

type evaluated =
  { response : Typesafeai_types.eval_response
  ; destination_uri : string
  ; request_body_sha256 : string
  }

type failure =
  | Transport_failure of string
  | Http_response_failure of
      { status : int
      ; destination_uri : string
      ; body : string
      ; detail : string
      }

let endpoint_for_observation endpoint =
  Uri.of_string endpoint
  |> fun uri -> Uri.with_userinfo uri None
  |> fun uri -> Uri.with_query uri []
  |> fun uri -> Uri.with_fragment uri None
  |> Uri.to_string
;;

let redact_diagnostic ~endpoint ~api_key detail =
  let displayed = endpoint_for_observation endpoint in
  let normalized = Uri.of_string endpoint |> Uri.to_string in
  detail
  |> String_util.replace_substring ~needle:endpoint ~by:displayed
  |> String_util.replace_substring ~needle:normalized ~by:displayed
  |> String_util.replace_substring ~needle:api_key ~by:"[REDACTED]"
  |> Observability_redact.redact_text
  |> String_util.sanitize_utf8
;;

let transport_failure ~endpoint ~api_key detail =
  Transport_failure (redact_diagnostic ~endpoint ~api_key detail)
;;

let failure_to_string = function
  | Transport_failure detail -> "typesafeai: transport failure: " ^ detail
  | Http_response_failure { status; destination_uri; detail; _ } ->
    Printf.sprintf "typesafeai: HTTP %d returned by %s: %s" status destination_uri detail
;;

let failure_to_yojson = function
  | Transport_failure detail ->
    `Assoc [ "kind", `String "transport"; "detail", `String detail ]
  | Http_response_failure { status; destination_uri; body; detail } ->
    let body =
      if String_util.is_valid_utf8 body then `String body
      else `Assoc
        [ "encoding", `String "base64"
        ; "content", `String (Base64.encode_string body)
        ; "total_bytes", `Int (String.length body)
        ]
    in
    `Assoc
      [ "kind", `String "http_response"
      ; "status", `Int status
      ; "destination_uri", `String destination_uri
      ; "body", body
      ; "detail", `String detail
      ]
;;

let evaluate
      ?(endpoint = Typesafeai_config.endpoint ())
      ?(model = Typesafeai_config.model ())
      ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
      ?clock
      ~api_key
      ~state
      ~questions
      ()
  =
  let request_json = Typesafeai_types.request_to_yojson ~model ~state ~questions in
  let body = Yojson.Safe.to_string request_json in
  let request_body_sha256 =
    Digestif.SHA256.(digest_string body |> to_hex)
  in
  let headers =
    [ "authorization", "Bearer " ^ api_key
    ; "content-type", "application/json"
    ; "accept", "application/json"
    ]
  in
  let* status, response_body =
    Masc_http_client.post_sync
      ?clock
      ~timeout_sec
      ~url:endpoint
      ~headers
      ~body
      ()
    |> Result.map_error (transport_failure ~endpoint ~api_key)
  in
  let failed detail =
    Error
      (Http_response_failure
         { status
         ; destination_uri = endpoint_for_observation endpoint
         ; body = response_body
         ; detail = redact_diagnostic ~endpoint ~api_key detail
         })
  in
  if not (String_util.is_valid_utf8 response_body) then
    failed "response body is not valid UTF-8"
  else if status = 200
  then
    let* parsed_json =
      match Yojson.Safe.from_string response_body with
      | json -> Ok json
      | exception Yojson.Json_error msg ->
        failed ("invalid response JSON: " ^ msg)
    in
    (match Typesafeai_types.eval_response_of_yojson parsed_json with
     | Error detail -> failed detail
     | Ok response ->
       Ok
         { response
         ; destination_uri = endpoint_for_observation endpoint
         ; request_body_sha256
         })
  else
    failed response_body
;;

module For_testing = struct
  let transport_failure = transport_failure
end
