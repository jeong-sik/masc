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
  ; destination : destination_id
  ; request_body_sha256 : string
  ; passed_over : attempt list
  }

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

(* Every refusal moves the walk on, whatever it says. The destinations share
   the state and the questions but not the body: each is asked for its own
   model id, and their limits differ, so one server calling a request wrong
   or too large says nothing about the next. A request that really is wrong
   costs one refused call per destination and ends with all of them on
   record. *)
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
        ; destination = identify destination
        ; request_body_sha256
        ; passed_over = attempts_so_far refused_so_far
        }
    | Error refusal ->
      let asked = identify destination in
      let attempt =
        { destination_uri = asked.destination_uri; model = asked.model; refusal }
      in
      let refused =
        match refused_so_far with
        | None -> { first_attempt = attempt; later_attempts = [] }
        | Some { first_attempt; later_attempts } ->
          { first_attempt; later_attempts = later_attempts @ [ attempt ] }
      in
      (match rest with
       | next :: rest -> walk (Some refused) next rest
       | [] -> Error refused)
  in
  walk None first rest
;;

module For_testing = struct
  let transport_failure = transport_failure
end
