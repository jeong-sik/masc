module Event = Keeper_operation_event
module Compaction_codec = Keeper_compaction_operation_codec

module Cursor = struct
  type t = int
  type error = Negative of int
  let zero = 0
  let of_int value = if value < 0 then Error (Negative value) else Ok value
  let to_int value = value
end

type row =
  { recorded_at : float
  ; start_cursor : Cursor.t
  ; end_cursor : Cursor.t
  ; event : Event.t
  }

type compaction_event_error =
  | Compaction_invalid_structure
  | Compaction_unknown_kind of string
  | Compaction_invalid_identity
  | Compaction_invalid_reference
  | Compaction_invalid_payload

type envelope_error =
  | Expected_object
  | Unknown_field of string
  | Duplicate_field of string
  | Missing_field of string
  | Invalid_recorded_at
  | Invalid_domain
  | Unknown_domain of string
  | Invalid_compaction_event of compaction_event_error

type issue =
  | Incomplete_tail
  | Malformed_json of string
  | Invalid_envelope of envelope_error

type decode_error =
  { row_number : int option
  ; start_cursor : Cursor.t
  ; end_cursor : Cursor.t
  ; issue : issue
  }

let ( let* ) = Result.bind
let compaction_domain = "compaction"

let compaction_event_error = function
  | Compaction_codec.Expected_object _
  | Compaction_codec.Invalid_field _ -> Compaction_invalid_structure
  | Compaction_codec.Unknown_event_kind kind
  | Compaction_codec.Unknown_failure_kind kind
  | Compaction_codec.Unknown_reconciliation_reason kind
  | Compaction_codec.Unknown_producer_kind kind
  | Compaction_codec.Unknown_provider_delivery_kind kind ->
    Compaction_unknown_kind kind
  | Compaction_codec.Invalid_operation_id _
  | Compaction_codec.Invalid_attempt_id _
  | Compaction_codec.Invalid_keeper_name _
  | Compaction_codec.Invalid_trace_id _
  | Compaction_codec.Invalid_cause _ -> Compaction_invalid_identity
  | Compaction_codec.Invalid_checkpoint _
  | Compaction_codec.Invalid_provider_delivery _
  | Compaction_codec.Invalid_keeper_chat_delivery _
  | Compaction_codec.Invalid_tool_producer _
  | Compaction_codec.Invalid_turn_ref _ -> Compaction_invalid_reference
  | Compaction_codec.Invalid_trigger _
  | Compaction_codec.Invalid_provider_delivery_sequence _
  | Compaction_codec.Invalid_evidence _ -> Compaction_invalid_payload
;;

let required_field name fields =
  match List.filter (fun (field, _) -> String.equal field name) fields with
  | [] -> Error (Missing_field name)
  | [ _, value ] -> Ok value
  | _ -> Error (Duplicate_field name)
;;

let decode_event domain json =
  if String.equal domain compaction_domain
  then
    Compaction_codec.of_json json
    |> Result.map_error (fun error ->
      Invalid_compaction_event (compaction_event_error error))
    |> Result.map (fun event -> Event.Compaction event)
  else Error (Unknown_domain domain)
;;

let encode_event = function
  | Event.Compaction event ->
    compaction_domain, Compaction_codec.to_json event
;;

let decode_envelope = function
  | `Assoc fields ->
    let* () =
      match
        List.find_opt
          (fun (name, _) ->
             not
               (String.equal name "recorded_at"
                || String.equal name "domain"
                || String.equal name "event"))
          fields
      with
      | None -> Ok ()
      | Some (name, _) -> Error (Unknown_field name)
    in
    let* recorded_json = required_field "recorded_at" fields in
    let* recorded_at =
      match recorded_json with
      | `Float value when Float.is_finite value -> Ok value
      | _ -> Error Invalid_recorded_at
    in
    let* domain_json = required_field "domain" fields in
    let* domain =
      match domain_json with
      | `String value -> Ok value
      | _ -> Error Invalid_domain
    in
    let* event_json = required_field "event" fields in
    decode_event domain event_json
    |> Result.map (fun event -> recorded_at, event)
  | _ -> Error Expected_object
;;

let encode ~recorded_at event =
  if not (Float.is_finite recorded_at)
  then Error Invalid_recorded_at
  else
    let domain, event = encode_event event in
    Ok
      (`Assoc
         [ "recorded_at", `Float recorded_at
         ; "domain", `String domain
         ; "event", event
         ]
       |> Yojson.Safe.to_string
       |> fun value -> value ^ "\n")
;;

let decode_rows ~from ~row_number bytes =
  let base = Cursor.to_int from in
  let length = String.length bytes in
  let locate number start_cursor end_cursor issue =
    Error { row_number = number; start_cursor; end_cursor; issue }
  in
  let rec loop position number rows =
    if position = length
    then Ok (List.rev rows)
    else
      match String.index_from_opt bytes position '\n' with
      | None ->
        locate number (base + position) (base + length) Incomplete_tail
      | Some newline ->
        let start_cursor = base + position in
        let end_cursor = base + newline + 1 in
        let payload = String.sub bytes position (newline - position) in
        (match
           try Ok (Yojson.Safe.from_string payload) with
           | Yojson.Json_error detail -> Error (Malformed_json detail)
         with
         | Error issue -> locate number start_cursor end_cursor issue
         | Ok json ->
           (match decode_envelope json with
            | Error error ->
              locate number start_cursor end_cursor (Invalid_envelope error)
            | Ok (recorded_at, event) ->
              loop
                (newline + 1)
                (Option.map succ number)
                ({ recorded_at; start_cursor; end_cursor; event } :: rows)))
  in
  loop 0 row_number []
;;
