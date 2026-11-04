open Result.Syntax

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
  let request_body_sha256 = Agent_core_sha256.(digest_string body |> to_hex) in
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

type refusal_class =
  | Payment_required
  | Credential_refused
  | Rate_limited
  | Server_error
  | Request_refused
  | Response_unusable
  | Transport

let refusal_class = function
  | Transport_failure _ -> Transport
  | Http_response_failure { status; _ } ->
    if status = 402 then Payment_required
    else if status = 401 || status = 403 then Credential_refused
    else if status = 429 then Rate_limited
    else if status >= 500 && status <= 599 then Server_error
    else if status >= 400 && status <= 499 then Request_refused
    else Response_unusable
;;

let refusal_class_to_string = function
  | Payment_required -> "payment_required"
  | Credential_refused -> "credential_refused"
  | Rate_limited -> "rate_limited"
  | Server_error -> "server_error"
  | Request_refused -> "request_refused"
  | Response_unusable -> "response_unusable"
  | Transport -> "transport"
;;

type destination_outcome =
  | Answered of { at : float }
  | Refusing of
      { since : float
      ; last_at : float
      ; last : refusal_class
      ; last_answer_at : float option
      }

module Destination_key = struct
  type t = destination_id

  let compare (a : t) (b : t) =
    match String.compare a.destination_uri b.destination_uri with
    | 0 -> String.compare a.model b.model
    | order -> order
  ;;
end

module Outcomes = Map.Make (Destination_key)

(* The latest outcome of every destination this process asked (RFC-0484
   §3.2). An immutable map behind an atomic: asks run on several fibers and
   domains, readers take a snapshot without waiting, and nothing here
   decides a call. *)
let outcomes : destination_outcome Outcomes.t Atomic.t = Atomic.make Outcomes.empty

let note_outcome key update =
  Atomic_util.update outcomes (fun current ->
    Outcomes.update key (fun previous -> Some (update previous)) current)
;;

let note_answer key ~at = note_outcome key (fun _ -> Answered { at })

let note_refusal key ~at refusal =
  let last = refusal_class refusal in
  note_outcome key (function
    | None -> Refusing { since = at; last_at = at; last; last_answer_at = None }
    | Some (Answered { at = answered_at }) ->
      Refusing { since = at; last_at = at; last; last_answer_at = Some answered_at }
    | Some (Refusing refusing) -> Refusing { refusing with last_at = at; last })
;;

let destination_outcomes () = Outcomes.bindings (Atomic.get outcomes)

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
      note_answer (identify destination) ~at:(Time_compat.now ());
      Ok
        { response
        ; destination = identify destination
        ; request_body_sha256
        ; passed_over = attempts_so_far refused_so_far
        }
    | Error refusal ->
      let asked = identify destination in
      note_refusal asked ~at:(Time_compat.now ()) refusal;
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

type failure_kind = Capacity_refused | Other_refusal

let failure_kind failure =
  let unique_field name fields =
    match List.filter (fun (key,_) -> String.equal key name) fields with
    | [_,value] -> Some value | [] | _ :: _ -> None in
  let capacity (attempt : attempt) = match attempt.refusal with
    | Http_response_failure {status=400;body;_} ->
      (try match Yojson.Safe.from_string body with
       | `Assoc fields ->
         (match unique_field "detail" fields with
          | Some (`Assoc detail) -> unique_field "error_type" detail = Some (`String "max_tokens_exceeded")
          | _ -> false)
       | _ -> false
       with Yojson.Json_error _ -> false)
    | Transport_failure _ | Http_response_failure _ -> false in
  if List.for_all capacity (attempts failure) then Capacity_refused else Other_refusal
