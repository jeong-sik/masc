module Canonical_json = struct
  type t = Yojson.Safe.t

  type error =
    | Duplicate_field of string
    | Invalid_utf8 of string
    | Non_finite_number
    | Unsupported_json_shape
    | Malformed_json of string

  let error_to_string = function
    | Duplicate_field field -> Printf.sprintf "duplicate JSON field %S" field
    | Invalid_utf8 path -> path ^ " contains malformed UTF-8"
    | Non_finite_number -> "JSON contains a non-finite number"
    | Unsupported_json_shape -> "JSON contains a non-standard tuple or variant"
    | Malformed_json detail -> "malformed JSON: " ^ detail
  ;;

  let valid_integer_literal value =
    let length = String.length value in
    let first_digit =
      if length > 0 && Char.equal value.[0] '-' then 1 else 0
    in
    if first_digit = length
    then false
    else if Char.equal value.[first_digit] '0'
    then first_digit + 1 = length
    else
      match value.[first_digit] with
      | '1' .. '9' ->
        let rec loop index =
          if index = length
          then true
          else
            match value.[index] with
            | '0' .. '9' -> loop (index + 1)
            | _ -> false
        in
        loop (first_digit + 1)
      | _ -> false
  ;;

  let rec normalize ~path = function
    | `Null as value -> Ok value
    | `Bool _ as value -> Ok value
    | `Int _ as value -> Ok value
    | `Intlit value as json ->
      if not (String.is_valid_utf_8 value)
      then Error (Invalid_utf8 path)
      else if valid_integer_literal value
      then Ok json
      else Error (Malformed_json (path ^ " contains an invalid integer literal"))
    | `Float value as json ->
      if Float.is_finite value then Ok json else Error Non_finite_number
    | `String value as json ->
      if String.is_valid_utf_8 value then Ok json else Error (Invalid_utf8 path)
    | `List values ->
      let rec loop index acc = function
        | [] -> Ok (`List (List.rev acc))
        | value :: rest ->
          (match normalize ~path:(Printf.sprintf "%s[%d]" path index) value with
           | Error _ as error -> error
           | Ok value -> loop (index + 1) (value :: acc) rest)
      in
      loop 0 [] values
    | `Assoc fields ->
      let sorted = List.sort (fun (left, _) (right, _) -> String.compare left right) fields in
      let rec loop previous acc = function
        | [] -> Ok (`Assoc (List.rev acc))
        | (field, value) :: rest ->
          if not (String.is_valid_utf_8 field)
          then Error (Invalid_utf8 (path ^ ".<field>"))
          else if Option.exists (String.equal field) previous
          then Error (Duplicate_field field)
          else
            (match normalize ~path:(path ^ "." ^ field) value with
             | Error _ as error -> error
             | Ok value -> loop (Some field) ((field, value) :: acc) rest)
      in
      loop None [] sorted
    | `Tuple _ | `Variant _ -> Error Unsupported_json_shape
  ;;

  let of_yojson json = normalize ~path:"$" json

  let of_string bytes =
    if not (String.is_valid_utf_8 bytes)
    then Error (Invalid_utf8 "JSON bytes")
    else
      try of_yojson (Yojson.Safe.from_string bytes) with
      | Yojson.Json_error detail -> Error (Malformed_json detail)
  ;;

  let to_yojson value = value
  let to_bytes value = Yojson.Safe.to_string value
end

type kind =
  | Message
  | Stimulus
  | Autonomous

let ( let* ) = Result.bind

let kind_to_string = function
  | Message -> "message"
  | Stimulus -> "stimulus"
  | Autonomous -> "autonomous"
;;

let valid_identity ~field value =
  if String.equal value ""
  then Error (field ^ " must not be empty")
  else if not (String.is_valid_utf_8 value)
  then Error (field ^ " contains malformed UTF-8")
  else Ok value
;;

module Source_ref = struct
  type t =
    | Operator_message of { request_id : string }
    | Discord_message of
        { guild_id : string
        ; channel_id : string
        ; message_id : string
        }
    | Slack_message of
        { team_id : string
        ; channel_id : string
        ; message_ts : string
        }
    | Keeper_message of
        { keeper_name : string
        ; causing_operation_id : Keeper_operation_id.Operation_id.t
        ; tool_call_id : string
        ; ordinal : int
        }
    | Event of { event_id : string }
    | Continuation of
        { causal_parent_operation_id : Keeper_operation_id.Operation_id.t
        ; delta_ref : string
        }
    | Autonomous_candidate of { candidate_id : string }

  let to_canonical_json source =
    let open Result in
    let json =
      match source with
      | Operator_message { request_id } ->
        let* request_id = valid_identity ~field:"operator request_id" request_id in
        Ok
          (`Assoc
             [ "kind", `String "operator_message"
             ; "request_id", `String request_id
             ])
      | Discord_message { guild_id; channel_id; message_id } ->
        let* guild_id = valid_identity ~field:"Discord guild_id" guild_id in
        let* channel_id = valid_identity ~field:"Discord channel_id" channel_id in
        let* message_id = valid_identity ~field:"connector message_id" message_id in
        Ok
          (`Assoc
             [ "kind", `String "discord_message"
             ; "guild_id", `String guild_id
             ; "channel_id", `String channel_id
             ; "message_id", `String message_id
             ])
      | Slack_message { team_id; channel_id; message_ts } ->
        let* team_id = valid_identity ~field:"Slack team_id" team_id in
        let* channel_id = valid_identity ~field:"Slack channel_id" channel_id in
        let* message_ts = valid_identity ~field:"Slack message_ts" message_ts in
        Ok
          (`Assoc
             [ "kind", `String "slack_message"
             ; "team_id", `String team_id
             ; "channel_id", `String channel_id
             ; "message_ts", `String message_ts
             ])
      | Keeper_message
          { keeper_name; causing_operation_id; tool_call_id; ordinal } ->
        let* keeper_name = valid_identity ~field:"source Keeper name" keeper_name in
        let* tool_call_id = valid_identity ~field:"host tool_call_id" tool_call_id in
        if ordinal < 0
        then Error "source Keeper message ordinal must be non-negative"
        else
          Ok
            (`Assoc
               [ "kind", `String "keeper_message"
               ; "keeper_name", `String keeper_name
               ; ( "causing_operation_id"
                 , `String
                     (Keeper_operation_id.Operation_id.to_string causing_operation_id) )
               ; "tool_call_id", `String tool_call_id
               ; "ordinal", `Int ordinal
               ])
      | Event { event_id } ->
        let* event_id = valid_identity ~field:"Event id" event_id in
        Ok (`Assoc [ "kind", `String "event"; "event_id", `String event_id ])
      | Continuation { causal_parent_operation_id; delta_ref } ->
        let* delta_ref = valid_identity ~field:"continuation delta_ref" delta_ref in
        Ok
          (`Assoc
             [ "kind", `String "continuation"
             ; ( "causal_parent_operation_id"
               , `String
                   (Keeper_operation_id.Operation_id.to_string
                      causal_parent_operation_id) )
             ; "delta_ref", `String delta_ref
             ])
      | Autonomous_candidate { candidate_id } ->
        let* candidate_id = valid_identity ~field:"autonomous candidate_id" candidate_id in
        Ok
          (`Assoc
             [ "kind", `String "autonomous_candidate"
             ; "candidate_id", `String candidate_id
             ])
    in
    let* json = json in
    Canonical_json.of_yojson json |> map_error Canonical_json.error_to_string
  ;;
end

module Submitter_ref = struct
  type t =
    | Operator of { principal_id : string }
    | Connector of { authenticated_identity : string }
    | Keeper of { keeper_name : string }
    | System

  let to_canonical_json submitter =
    let open Result in
    let json =
      match submitter with
      | Operator { principal_id } ->
        let* principal_id = valid_identity ~field:"operator principal_id" principal_id in
        Ok
          (`Assoc
             [ "kind", `String "operator"
             ; "principal_id", `String principal_id
             ])
      | Connector { authenticated_identity } ->
        let* authenticated_identity =
          valid_identity
            ~field:"connector authenticated_identity"
            authenticated_identity
        in
        Ok
          (`Assoc
             [ "kind", `String "connector"
             ; "authenticated_identity", `String authenticated_identity
             ])
      | Keeper { keeper_name } ->
        let* keeper_name = valid_identity ~field:"submitter Keeper name" keeper_name in
        Ok
          (`Assoc
             [ "kind", `String "keeper"
             ; "keeper_name", `String keeper_name
             ])
      | System -> Ok (`Assoc [ "kind", `String "system" ])
    in
    let* json = json in
    Canonical_json.of_yojson json |> map_error Canonical_json.error_to_string
  ;;
end

type t =
  { operation_id : Keeper_operation_id.Operation_id.t
  ; kind : kind
  ; source_ref : Source_ref.t
  ; submitter_ref : Submitter_ref.t
  ; input : Canonical_json.t
  ; canonical_bytes : string
  ; request_digest : string
  }

let source_matches_kind kind source =
  match kind, source with
  | Message, (Source_ref.Operator_message _ | Discord_message _ | Slack_message _ | Keeper_message _) ->
    true
  | Stimulus, (Source_ref.Event _ | Continuation _) -> true
  | Autonomous, Source_ref.Autonomous_candidate _ -> true
  | Message, (Event _ | Continuation _ | Autonomous_candidate _)
  | Stimulus, (Operator_message _ | Discord_message _ | Slack_message _ | Keeper_message _ | Autonomous_candidate _)
  | Autonomous, (Operator_message _ | Discord_message _ | Slack_message _ | Keeper_message _ | Event _ | Continuation _) ->
    false
;;

let make ~operation_id ~kind ~source_ref ~submitter_ref ~input =
  let open Result in
  if not (source_matches_kind kind source_ref)
  then Error "operation kind does not match its typed source"
  else
    let* source_json = Source_ref.to_canonical_json source_ref in
    let* submitter_json = Submitter_ref.to_canonical_json submitter_ref in
    let envelope =
      `Assoc
        [ "schema", `String "masc.keeper_operation.request.v1"
        ; "kind", `String (kind_to_string kind)
        ; "source_ref", Canonical_json.to_yojson source_json
        ; "submitter_ref", Canonical_json.to_yojson submitter_json
        ; "input", Canonical_json.to_yojson input
        ]
    in
    let* envelope =
      Canonical_json.of_yojson envelope |> map_error Canonical_json.error_to_string
    in
    let canonical_bytes = Canonical_json.to_bytes envelope in
    let request_digest =
      Digestif.SHA256.(digest_string canonical_bytes |> to_hex)
    in
    Ok
      { operation_id
      ; kind
      ; source_ref
      ; submitter_ref
      ; input
      ; canonical_bytes
      ; request_digest
      }
;;

let operation_id t = t.operation_id
let kind t = t.kind
let source_ref t = t.source_ref
let submitter_ref t = t.submitter_ref
let input t = t.input
let canonical_bytes t = t.canonical_bytes
let request_digest t = t.request_digest
