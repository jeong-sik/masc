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

type text_owner =
  | Observed_response of response_owner
  | Unobserved_scope of int option

type event =
  | Run_started
  | Runtime_attempt_started
  | Text_delta of { text : string; owner : text_owner }
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
let decode_response_owner json =
  let* () =
    require_exact_object_fields "text_delta response"
      [ "content_generation"; "stream_scope" ]
      json
  in
  let* content_generation =
    required_nonnegative_int_field json "content_generation"
  in
  let* stream_scope = required_nonnegative_int_field json "stream_scope" in
  Ok { content_generation; stream_scope }

(* Keeper_chat_events.text_response_of_fields ~owner_field:"response"
   ~scope_field:"stream_scope": an observed response, a bare scope, or
   neither; both, or either twice, is malformed. *)
let decode_text_owner fields =
  let named key =
    List.filter_map
      (fun (name, value) -> if String.equal name key then Some value else None)
      fields
  in
  match named "response", named "stream_scope" with
  | [], [] -> Ok (Unobserved_scope None)
  | [ owner ], [] ->
      Result.map
        (fun owner -> Observed_response owner)
        (decode_response_owner owner)
  | [], [ scope ] -> (
      match scope with
      | `Int value when value >= 0 -> Ok (Unobserved_scope (Some value))
      | `Int _ | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _
      | `List _ ->
          Error "text_delta stream_scope must be a nonnegative integer")
  | _ :: _ :: _, _ | _, _ :: _ :: _ | _ :: _, _ :: _ ->
      Error "text_delta has conflicting or duplicate ownership fields"

(* Every tag Keeper_chat_event_log.keeper_chat_event_to_json writes. The
   connectors' reply fold reads five of them (Keeper_chat_discord,
   Keeper_chat_slack); the rest leave the reply text as it is. *)
let decode_event ~fields body =
  let* tag = required_string_field body "type" in
  match tag with
  | "run_started" -> Ok Run_started
  | "agent_core_runtime_attempt_started" -> Ok Runtime_attempt_started
  | "text_delta" ->
      let* text = required_string_field body "delta" in
      let* owner = decode_text_owner fields in
      Ok (Text_delta { text; owner })
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
  | "agent_core_media_delta"
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
  | "image_block"
  | "status_block"
  | "audio_block"
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
