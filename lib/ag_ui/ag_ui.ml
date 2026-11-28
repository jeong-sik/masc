(** AG-UI Protocol — Agent-User Interface Event Bridge

    Translates MASC internal events to AG-UI protocol format (CopilotKit standard).
    AG-UI sits at Layer 1 (Agent↔User) complementing MCP (Layer 2) and A2A (Layer 3).

    Event categories:
    - Lifecycle: RUN_STARTED, RUN_FINISHED, RUN_ERROR
    - Text: TEXT_MESSAGE_START, TEXT_MESSAGE_CONTENT, TEXT_MESSAGE_END
    - Tool: TOOL_CALL_START, TOOL_CALL_ARGS, TOOL_CALL_END
    - Custom: CUSTOM (MASC-specific events)

    The frame types and their JSON are generated from
    lib/keeper_chat_wire/keeper_chat_wire.atd, the definition native clients
    are generated from too.

    @see https://docs.ag-ui.com/concepts/events
    @since 2.60.0 *)

module Wire = Keeper_chat_wire.Keeper_chat_wire_t
module Wire_json = Keeper_chat_wire.Keeper_chat_wire_j

type response_identity = { response_generation : int; response_scope : int }

type text_response =
  | Unobserved_scope of int option
  | Observed_response of response_identity

type role = Wire.role = User | Assistant | System | Tool

type custom_name = Wire.custom_name

type event = Wire.frame

type tool_stream_occurrence =
  { stream_scope : int
  ; provider_message_id : string option
  ; block_index : int
  }

type tool_call_arguments =
  | Arguments_delta of string
  | Arguments_snapshot of string

let run_started ?(timestamp = Time_compat.now ()) ~thread_id ~run_id () : event =
  Run_started { thread_id; timestamp; run_id }

let run_finished ?(timestamp = Time_compat.now ()) ~thread_id ~run_id () : event =
  Run_finished { thread_id; timestamp; run_id }

let run_error ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ~message ?code () : event =
  if String.equal (String.trim message) "" then
    invalid_arg "AG-UI RUN_ERROR requires a non-empty top-level message";
  Run_error { thread_id; timestamp; run_id; message; code }

let text_message_start ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ~message_id ~role ()
  : event =
  Text_message_start { thread_id; timestamp; run_id; message_id; role }

(* textResponse names the observed provider response; without one the frame
   carries at most textStreamScope. The wire names the two numbers
   content_generation and stream_scope; Ag_ui.response_identity calls them
   response_generation and response_scope. *)
let text_message_content ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ?message_id
    ?(text_response = Unobserved_scope None) ~delta () : event =
  let text_stream_scope, response =
    match text_response with
    | Unobserved_scope scope -> scope, None
    | Observed_response { response_generation; response_scope } ->
      None, Some { Wire.content_generation = response_generation; stream_scope = response_scope }
  in
  Text_message_content
    { thread_id; timestamp; run_id; message_id; delta; text_stream_scope; text_response = response }

let text_message_end ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ?message_id () : event =
  Text_message_end { thread_id; timestamp; run_id; message_id }

let tool_call_start ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ?tool_call_id
    ~tool_call_name (occurrence : tool_stream_occurrence) : event =
  Tool_call_start
    { thread_id
    ; timestamp
    ; run_id
    ; tool_call_id
    ; tool_stream_scope = occurrence.stream_scope
    ; provider_message_id = occurrence.provider_message_id
    ; tool_call_block_index = occurrence.block_index
    ; tool_call_name
    }

let tool_call_args ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ?tool_call_id
    (occurrence : tool_stream_occurrence) arguments : event =
  let delta, snapshot =
    match arguments with
    | Arguments_delta delta -> Some delta, None
    | Arguments_snapshot snapshot -> None, Some snapshot
  in
  Tool_call_args
    { thread_id
    ; timestamp
    ; run_id
    ; tool_call_id
    ; tool_stream_scope = occurrence.stream_scope
    ; provider_message_id = occurrence.provider_message_id
    ; tool_call_block_index = occurrence.block_index
    ; delta
    ; snapshot
    }

let tool_call_end ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ?tool_call_id
    (occurrence : tool_stream_occurrence) : event =
  Tool_call_end
    { thread_id
    ; timestamp
    ; run_id
    ; tool_call_id
    ; tool_stream_scope = occurrence.stream_scope
    ; provider_message_id = occurrence.provider_message_id
    ; tool_call_block_index = occurrence.block_index
    }

let custom ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ~name value : event =
  Custom { thread_id; timestamp; run_id; name; value }

let event_to_json (e : event) : Yojson.Safe.t =
  Yojson.Safe.from_string (Wire_json.string_of_frame e)

(* The generated writer's compact JSON has no raw newline, so it is one
   data line. *)
let event_to_sse ?id (e : event) : string =
  Sse_wire.format_event ?id (Wire_json.string_of_frame e)

(** Default thread ID for the single-namespace AG-UI bridge. *)
let default_thread_id = "default"

let of_custom ?timestamp ~name (value : Yojson.Safe.t) : event =
  custom ?timestamp ~thread_id:default_thread_id ~name value

(** Protocol version *)
let protocol_version = "0.1.0"
