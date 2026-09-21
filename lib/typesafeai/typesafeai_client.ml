let ( let* ) = Result.bind

type destination =
  { endpoint : string
  ; model : string
  ; api_key : string
  }

type destination_id =
  { destination_uri : string
  ; model : string
  }

type refusal =
  | Transport_failure of string
  | Http_response_failure of
      { status : int
      ; destination_uri : string
      ; body : string
      ; detail : string
      }

type attempt =
  { destination_uri : string
  ; model : string
  ; refusal : refusal
  }

type failure =
  { first_attempt : attempt
  ; later_attempts : attempt list
  }

type evaluated =
  { response : Typesafeai_types.eval_response
  ; destination_uri : string
  ; request_body_sha256 : string
  ; passed_over : attempt list
  }

type disposition =
  | Ask_next_destination
  | Stop_walk

let endpoint_for_observation endpoint =
  Uri.of_string endpoint
  |> fun uri -> Uri.with_userinfo uri None
  |> fun uri -> Uri.with_query uri []
  |> fun uri -> Uri.with_fragment uri None
  |> Uri.to_string
;;

let identify (destination : destination) : destination_id =
  { destination_uri = endpoint_for_observation destination.endpoint
  ; model = destination.model
  }
;;

let destination_id_to_yojson ({ destination_uri; model } : destination_id) =
  `Assoc [ "destination_uri", `String destination_uri; "model", `String model ]
;;

let redact_credentials ~endpoint ~api_key detail =
  let displayed = endpoint_for_observation endpoint in
  let normalized = Uri.of_string endpoint |> Uri.to_string in
  detail
  |> String_util.replace_substring ~needle:endpoint ~by:displayed
  |> String_util.replace_substring ~needle:normalized ~by:displayed
  |> String_util.replace_substring ~needle:api_key ~by:"[REDACTED]"
;;

let redact_diagnostic ~endpoint ~api_key detail =
  redact_credentials ~endpoint ~api_key detail
  |> Observability_redact.redact_text
  |> String_util.sanitize_utf8
;;

let transport_failure ~endpoint ~api_key detail =
  Transport_failure (redact_diagnostic ~endpoint ~api_key detail)
;;

let refusal_to_string = function
  | Transport_failure detail -> "typesafeai: transport failure: " ^ detail
  | Http_response_failure { status; destination_uri; detail; _ } ->
    Printf.sprintf "typesafeai: HTTP %d returned by %s: %s" status destination_uri detail
;;

let refusal_to_yojson = function
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

let attempts { first_attempt; later_attempts } = first_attempt :: later_attempts

let attempt_to_yojson { destination_uri; model; refusal } =
  `Assoc
    [ "destination_uri", `String destination_uri
    ; "model", `String model
    ; "refusal", refusal_to_yojson refusal
    ]
;;

let failure_to_string failure =
  match attempts failure with
  | [ only ] -> refusal_to_string only.refusal
  | asked ->
    "typesafeai: every destination refused: "
    ^ String.concat
        "; "
        (List.map
           (fun (attempt : attempt) ->
              Printf.sprintf
                "%s (%s): %s"
                attempt.destination_uri
                attempt.model
                (refusal_to_string attempt.refusal))
           asked)
;;

let failure_to_yojson failure =
  `Assoc
    [ "kind", `String "every_destination_refused"
    ; "attempts", `List (List.map attempt_to_yojson (attempts failure))
    ]
;;

(* The statuses both servers document as answers about the request body
   itself: OpenRouter 400 (malformed input) and 413 (payload too large),
   TypeSafe 422 (validation failed). The next destination would read the
   same bytes, so the walk stops there. Every other status is about the
   destination that returned it. *)
let request_refused_statuses = [ 400; 413; 422 ]

let disposition_of_refusal = function
  | Transport_failure _ -> Ask_next_destination
  | Http_response_failure { status; _ } ->
    if List.mem status request_refused_statuses then Stop_walk else Ask_next_destination
;;

(* One destination: post the body with its model id and decode what it
   returns. [Error] is that destination's refusal. *)
let ask ~timeout_sec ?clock ~state ~questions { endpoint; model; api_key } =
  let request_json = Typesafeai_types.request_to_yojson ~model ~state ~questions in
  let body = Yojson.Safe.to_string request_json in
  let request_body_sha256 = Digestif.SHA256.(digest_string body |> to_hex) in
  let headers =
    [ "authorization", "Bearer " ^ api_key
    ; "content-type", "application/json"
    ; "accept", "application/json"
    ]
  in
  let* status, response_body =
    Masc_http_client.post_sync ?clock ~timeout_sec ~url:endpoint ~headers ~body ()
    |> Result.map_error (transport_failure ~endpoint ~api_key)
  in
  let failed detail =
    Error
      (Http_response_failure
         { status
         ; destination_uri = endpoint_for_observation endpoint
         ; body = redact_credentials ~endpoint ~api_key response_body
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
      | exception Yojson.Json_error msg -> failed ("invalid response JSON: " ^ msg)
    in
    (match Typesafeai_types.eval_response_of_yojson parsed_json with
     | Error detail -> failed detail
     | Ok response -> Ok (response, request_body_sha256))
  else
    failed response_body
;;

let evaluate
      ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
      ?clock
      ~destinations:(first, rest)
      ~state
      ~questions
      ()
  =
  (* [refused_so_far] is every destination asked before this one, in the
     order asked; [None] before the first is asked. *)
  let attempts_so_far = function
    | None -> []
    | Some refused -> attempts refused
  in
  let rec walk refused_so_far destination rest =
    match ask ~timeout_sec ?clock ~state ~questions destination with
    | Ok (response, request_body_sha256) ->
      Ok
        { response
        ; destination_uri = endpoint_for_observation destination.endpoint
        ; request_body_sha256
        ; passed_over = attempts_so_far refused_so_far
        }
    | Error refusal ->
      let attempt =
        { destination_uri = endpoint_for_observation destination.endpoint
        ; model = destination.model
        ; refusal
        }
      in
      let refused =
        match refused_so_far with
        | None -> { first_attempt = attempt; later_attempts = [] }
        | Some { first_attempt; later_attempts } ->
          { first_attempt; later_attempts = later_attempts @ [ attempt ] }
      in
      (match disposition_of_refusal refusal, rest with
       | Ask_next_destination, next :: rest -> walk (Some refused) next rest
       | Ask_next_destination, [] | Stop_walk, _ -> Error refused)
  in
  walk None first rest
;;

module For_testing = struct
  let transport_failure = transport_failure
end
