open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

type cursor = {
  last_seq : int;
  next_offset : int;
}

type from =
  | From_start
  | After of cursor

let equal_from a b =
  match a, b with
  | From_start, From_start -> true
  | After x, After y ->
      Int.equal x.last_seq y.last_seq && Int.equal x.next_offset y.next_offset
  | From_start, After _ | After _, From_start -> false

type response_owner = {
  content_generation : int;
  stream_scope : int;
}

let compare_response_owner a b =
  match Int.compare a.content_generation b.content_generation with
  | 0 -> Int.compare a.stream_scope b.stream_scope
  | order -> order

type text_owner =
  | Observed_response of response_owner
  | Unobserved_scope of int option

type event =
  | Run_started
  | Runtime_attempt_started
  | Text_delta of { text : string; owner : text_owner }
  | Attachment_emitted of Wire_attachment.t
  | Media_delta of {
      mime_type : string option;
      url : string option;
      attachment_id : string option;
    }
  | Image_block of {
      url : string option;
      mime_type : string option;
      attachment_id : string option;
      caption : string option;
    }
  | Audio_block of {
      url : string option;
      mime_type : string option;
      attachment_id : string option;
      caption : string option;
    }
  | Run_finished
  | Event_error
  | Other

type page = {
  events : event list;
  next : cursor option;
}

let schema = "masc.keeper_chat_events.v2"

(* The route admits [1..Keeper_chat_event_log.page_max_limit]; the roundtrip
   test holds the two equal. *)
let page_limit = 2000

let path ~keeper ~operation_id ~from =
  let cursor =
    match from with
    | From_start -> []
    | After { last_seq; next_offset } ->
        [
          Printf.sprintf "since_seq=%d" last_seq;
          Printf.sprintf "since_offset=%d" next_offset;
        ]
  in
  let params =
    (("operation_id=" ^ percent_encode operation_id) :: cursor)
    @ [ Printf.sprintf "limit=%d" page_limit ]
  in
  Printf.sprintf "/api/v1/keepers/%s/chat/events?%s" (percent_encode keeper)
    (String.concat "&" params)

(* Keeper_chat_events.response_identity_of_json: exactly the two indexes. *)
let decode_response_owner ~owner_field json =
  let* () =
    require_exact_object_fields owner_field
      [ "content_generation"; "stream_scope" ]
      json
  in
  let* content_generation =
    required_nonnegative_int_field json "content_generation"
  in
  let* stream_scope = required_nonnegative_int_field json "stream_scope" in
  Ok { content_generation; stream_scope }

(* Keeper_chat_events.text_response_of_fields: an observed response, a bare
   scope, or neither; both, or either twice, is malformed. *)
let decode_text_owner_fields ~owner_field ~scope_field fields =
  let named key =
    List.filter_map
      (fun (name, value) -> if String.equal name key then Some value else None)
      fields
  in
  match named owner_field, named scope_field with
  | [], [] -> Ok (Unobserved_scope None)
  | [ owner ], [] ->
      Result.map
        (fun owner -> Observed_response owner)
        (decode_response_owner ~owner_field owner)
  | [], [ scope ] -> (
      match scope with
      | `Int value when value >= 0 -> Ok (Unobserved_scope (Some value))
      | `Int _ | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _
      | `List _ ->
          Error (Printf.sprintf "%s must be a nonnegative integer" scope_field))
  | _ :: _ :: _, _ | _, _ :: _ :: _ | _ :: _, _ :: _ ->
      Error
        (Printf.sprintf
           "conflicting or duplicate text ownership fields (%s / %s)"
           owner_field scope_field)

let decode_text_owner fields =
  decode_text_owner_fields ~owner_field:"response" ~scope_field:"stream_scope"
    fields

let first_nonblank body keys =
  List.find_map
    (fun k ->
      match optional_nonblank_string body k with
      | Ok (Some _ as v) -> v
      | Ok None | Error _ -> None)
    keys

(* Every tag Keeper_chat_event_log.keeper_chat_event_to_json writes. *)
let decode_event ~fields body =
  let* tag = required_string_field body "type" in
  match tag with
  | "run_started" -> Ok Run_started
  | "agent_core_runtime_attempt_started" -> Ok Runtime_attempt_started
  | "text_delta" ->
      let* text = required_string_field body "delta" in
      let* owner = decode_text_owner fields in
      Ok (Text_delta { text; owner })
  | "attachment_emitted" -> (
      let target =
        match optional_object_field body "attachment" with
        | Ok (Some obj) -> obj
        | Ok None | Error _ -> body
      in
      let* att = Wire_attachment.decode_attachment_ref target in
      Ok (Attachment_emitted att))
  | "agent_core_media_delta" ->
      let mime_type = first_nonblank body [ "mime_type"; "mimeType"; "media_type" ] in
      let url = first_nonblank body [ "url"; "src" ] in
      let attachment_id = first_nonblank body [ "attachment_id"; "id" ] in
      Ok (Media_delta { mime_type; url; attachment_id })
  | "image_block" ->
      let url = first_nonblank body [ "url"; "src" ] in
      let mime_type = first_nonblank body [ "mime_type"; "mimeType" ] in
      let attachment_id = first_nonblank body [ "attachment_id"; "id" ] in
      let caption = first_nonblank body [ "caption"; "cap"; "alt"; "filename" ] in
      Ok (Image_block { url; mime_type; attachment_id; caption })
  | "audio_block" ->
      let url = first_nonblank body [ "url"; "src" ] in
      let mime_type = first_nonblank body [ "mime_type"; "mimeType" ] in
      let attachment_id = first_nonblank body [ "attachment_id"; "id" ] in
      let caption = first_nonblank body [ "caption"; "cap"; "alt"; "filename" ] in
      Ok (Audio_block { url; mime_type; attachment_id; caption })
  | "run_finished" -> Ok Run_finished
  | "event_error" -> Ok Event_error
  | "batch_bound"
  | "text_message_start"
  | "text_message_end"
  | "external_effect_completed"
  | "reply_details"
  | "continuation_checkpoint"
  | "agent_core_stream_connected"
  | "provider_retry_observed"
  | "agent_core_stream_message_start"
  | "agent_core_stream_message_delta"
  | "agent_core_stream_message_stop"
  | "agent_core_stream_ping"
  | "agent_core_content_block_start"
  | "model_content_activity"
  | "agent_core_content_block_stop"
  | "agent_core_thinking_snapshot"
  | "agent_core_thinking_delta"
  | "agent_core_thinking_signature_delta"
  | "agent_core_stream_protocol_error"
  | "tool_call_start"
  | "tool_call_admitted"
  | "tool_call_args"
  | "tool_call_args_snapshot"
  | "tool_call_end"
  | "native_tool_start"
  | "native_tool_progress"
  | "native_tool_end"
  | "tool_approval_requested"
  | "tool_approval_settled"
  | "tool_result_ready"
  | "tool_transcript_committed"
  | "link_block"
  | "status_block"
  | "tool_context_block" ->
      Ok Other
  | unknown -> Error (Printf.sprintf "unknown journal event type %S" unknown)

(* One journaled row: [{v, seq, ts, event}]. *)
let decode_row json =
  match member "event" json with
  | `Assoc fields as body -> decode_event ~fields body
  | `Null -> Error "missing required field 'event'"
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error "field 'event' must be an object"

let decode_page ~operation_id json =
  let* page_schema = required_string_field json "schema" in
  let* () =
    if String.equal page_schema schema then Ok ()
    else Error (Printf.sprintf "schema %S is not %S" page_schema schema)
  in
  let* page_operation = required_string_field json "operation_id" in
  let* () =
    if String.equal page_operation operation_id then Ok ()
    else
      Error
        (Printf.sprintf "the page is for operation %S, not %S" page_operation
           operation_id)
  in
  let* rows = required_list_field json "events" in
  let* events = decode_list "events" decode_row rows in
  let* has_more = required_bool_field json "has_more" in
  let* next_since_seq = required_nullable_int_field json "next_since_seq" in
  let* next_offset = required_nonnegative_int_field json "next_since_offset" in
  match has_more, next_since_seq with
  | false, (Some _ | None) -> Ok { events; next = None }
  | true, Some last_seq -> Ok { events; next = Some { last_seq; next_offset } }
  | true, None -> Error "has_more is true but next_since_seq is null"
