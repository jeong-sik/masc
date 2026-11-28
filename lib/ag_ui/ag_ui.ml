(** AG-UI Protocol — Agent-User Interface Event Bridge

    Translates MASC internal events to AG-UI protocol format (CopilotKit standard).
    AG-UI sits at Layer 1 (Agent↔User) complementing MCP (Layer 2) and A2A (Layer 3).

    Event categories:
    - Lifecycle: RUN_STARTED, RUN_FINISHED, RUN_ERROR
    - Text: TEXT_MESSAGE_START, TEXT_MESSAGE_CONTENT, TEXT_MESSAGE_END
    - Tool: TOOL_CALL_START, TOOL_CALL_ARGS, TOOL_CALL_END
    - Custom: CUSTOM (MASC-specific events)

    @see https://docs.ag-ui.com/concepts/events
    @since 2.60.0 *)

(** AG-UI event types — subset relevant to MASC agent workspace *)
type response_identity = { response_generation : int; response_scope : int }

type text_response =
  | Unobserved_scope of int option
  | Observed_response of response_identity

type event_type =
  | Run_started
  | Run_finished
  | Run_error
  | Text_message_start
  | Text_message_content
  | Text_message_end
  | Tool_call_start
  | Tool_call_args
  | Tool_call_end
  | Custom
[@@deriving show, eq]

let event_type_to_string = function
  | Run_started -> "RUN_STARTED"
  | Run_finished -> "RUN_FINISHED"
  | Run_error -> "RUN_ERROR"
  | Text_message_start -> "TEXT_MESSAGE_START"
  | Text_message_content -> "TEXT_MESSAGE_CONTENT"
  | Text_message_end -> "TEXT_MESSAGE_END"
  | Tool_call_start -> "TOOL_CALL_START"
  | Tool_call_args -> "TOOL_CALL_ARGS"
  | Tool_call_end -> "TOOL_CALL_END"
  | Custom -> "CUSTOM"

(** AG-UI message role *)
type role = User | Assistant | System | Tool
[@@deriving show, eq]

let role_to_string = function
  | User -> "user"
  | Assistant -> "assistant"
  | System -> "system"
  | Tool -> "tool"

(** AG-UI event — typed event emitted over SSE *)
type event = {
  event_type: event_type;
  thread_id: string;
  run_id: string option;
  message_id: string option;
  role: role option;
  delta: string option;            (** Text chunk or tool args fragment *)
  tool_call_id: string option;
  tool_call_name: string option;
  text_response : text_response;
  tool_stream_scope: int option;
  provider_message_id: string option;
  tool_call_block_index: int option;
  snapshot: Yojson.Safe.t option;  (** Accumulated tool-call arguments for TOOL_CALL_ARGS *)
  message: string option;          (** Required top-level RUN_ERROR message *)
  code: string option;             (** Optional top-level RUN_ERROR code *)
  custom_name: string option;      (** Custom event name *)
  custom_value: Yojson.Safe.t option;
  timestamp: float;
}

type tool_stream_occurrence =
  { stream_scope : int
  ; provider_message_id : string option
  ; block_index : int
  }

type tool_call_arguments =
  | Arguments_delta of string
  | Arguments_snapshot of string

(* Every constructor starts from a frame with no optional field set and
   fills in only the fields its kind carries. *)
let bare ~timestamp ~thread_id event_type =
  { event_type
  ; thread_id
  ; run_id = None
  ; message_id = None
  ; role = None
  ; delta = None
  ; tool_call_id = None
  ; tool_call_name = None
  ; text_response = Unobserved_scope None
  ; tool_stream_scope = None
  ; provider_message_id = None
  ; tool_call_block_index = None
  ; snapshot = None
  ; message = None
  ; code = None
  ; custom_name = None
  ; custom_value = None
  ; timestamp
  }

let run_started ?(timestamp = Time_compat.now ()) ~thread_id ~run_id () =
  { (bare ~timestamp ~thread_id Run_started) with run_id = Some run_id }

let run_finished ?(timestamp = Time_compat.now ()) ~thread_id ~run_id () =
  { (bare ~timestamp ~thread_id Run_finished) with run_id = Some run_id }

let run_error ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ~message ?code () =
  if String.equal (String.trim message) "" then
    invalid_arg "AG-UI RUN_ERROR requires a non-empty top-level message";
  { (bare ~timestamp ~thread_id Run_error) with run_id; message = Some message; code }

let text_message_start ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ~message_id ~role () =
  { (bare ~timestamp ~thread_id Text_message_start) with
    run_id
  ; message_id = Some message_id
  ; role = Some role
  }

let text_message_content ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ?message_id
    ?(text_response = Unobserved_scope None) ~delta () =
  { (bare ~timestamp ~thread_id Text_message_content) with
    run_id
  ; message_id
  ; delta = Some delta
  ; text_response
  }

let text_message_end ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ?message_id () =
  { (bare ~timestamp ~thread_id Text_message_end) with run_id; message_id }

let tool_frame ~timestamp ~thread_id ~run_id ~tool_call_id
    (occurrence : tool_stream_occurrence) event_type =
  { (bare ~timestamp ~thread_id event_type) with
    run_id
  ; tool_call_id
  ; tool_stream_scope = Some occurrence.stream_scope
  ; provider_message_id = occurrence.provider_message_id
  ; tool_call_block_index = Some occurrence.block_index
  }

let tool_call_start ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ?tool_call_id
    ~tool_call_name occurrence =
  { (tool_frame ~timestamp ~thread_id ~run_id ~tool_call_id occurrence Tool_call_start) with
    tool_call_name = Some tool_call_name
  }

let tool_call_args ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ?tool_call_id
    occurrence arguments =
  let frame = tool_frame ~timestamp ~thread_id ~run_id ~tool_call_id occurrence Tool_call_args in
  match arguments with
  | Arguments_delta delta -> { frame with delta = Some delta }
  | Arguments_snapshot snapshot -> { frame with snapshot = Some (`String snapshot) }

let tool_call_end ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ?tool_call_id occurrence =
  tool_frame ~timestamp ~thread_id ~run_id ~tool_call_id occurrence Tool_call_end

let custom ?(timestamp = Time_compat.now ()) ~thread_id ?run_id ~name value =
  { (bare ~timestamp ~thread_id Custom) with
    run_id
  ; custom_name = Some name
  ; custom_value = Some value
  }

(** Serialize AG-UI event to JSON (spec-compliant field names) *)
let event_to_json (e : event) : Yojson.Safe.t =
  let required = [
    ("type", `String (event_type_to_string e.event_type));
    ("threadId", `String e.thread_id);
    ("timestamp", `Float e.timestamp);
  ] in
  let optional key f = function
    | None -> []
    | Some v -> [(key, f v)]
  in
  `Assoc (required
    @ optional "runId" (fun s -> `String s) e.run_id
    @ optional "messageId" (fun s -> `String s) e.message_id
    @ optional "role" (fun r -> `String (role_to_string r)) e.role
    @ optional "delta" (fun s -> `String s) e.delta
    @ optional "toolCallId" (fun s -> `String s) e.tool_call_id
    @ optional "toolCallName" (fun s -> `String s) e.tool_call_name
    @ (match e.text_response with
       | Unobserved_scope scope -> optional "textStreamScope" (fun value -> `Int value) scope
       | Observed_response owner -> ["textResponse", `Assoc
           ["content_generation", `Int owner.response_generation;
            "stream_scope", `Int owner.response_scope]])
    @ optional "toolStreamScope" (fun value -> `Int value) e.tool_stream_scope
    @ optional "providerMessageId" (fun s -> `String s) e.provider_message_id
    @ optional "toolCallBlockIndex" (fun value -> `Int value) e.tool_call_block_index
    @ optional "snapshot" (fun j -> j) e.snapshot
    @ optional "message" (fun s -> `String s) e.message
    @ optional "code" (fun s -> `String s) e.code
    @ optional "name" (fun s -> `String s) e.custom_name
    @ optional "value" (fun j -> j) e.custom_value)

(** Format as SSE data through the transport's canonical JSON encoder. *)
let event_to_sse ?id (e : event) : string =
  Sse_wire.format_event_yojson ?id (event_to_json e)

(** Default thread ID for the single-namespace AG-UI bridge. *)
let default_thread_id = "default"

(** Map any MASC-specific event to AG-UI CUSTOM *)
let of_custom ?timestamp ~name (value : Yojson.Safe.t) : event =
  custom ?timestamp ~thread_id:default_thread_id ~name value

(** Protocol version *)
let protocol_version = "0.1.0"
