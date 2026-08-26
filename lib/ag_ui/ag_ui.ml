(** AG-UI Protocol — Agent-User Interface Event Bridge

    Translates MASC internal events to AG-UI protocol format (CopilotKit standard).
    AG-UI sits at Layer 1 (Agent↔User) complementing MCP (Layer 2) and A2A (Layer 3).

    Event categories:
    - Lifecycle: RUN_STARTED, RUN_FINISHED, RUN_ERROR, STEP_STARTED, STEP_FINISHED
    - Text: TEXT_MESSAGE_START, TEXT_MESSAGE_CONTENT, TEXT_MESSAGE_END
    - Tool: TOOL_CALL_START, TOOL_CALL_ARGS, TOOL_CALL_END
    - State: STATE_SNAPSHOT, STATE_DELTA
    - Custom: CUSTOM (MASC-specific events)

    @see https://docs.ag-ui.com/concepts/events
    @since 2.60.0 *)

(** AG-UI event types — subset relevant to MASC agent workspace *)
type event_type =
  | Run_started
  | Run_finished
  | Run_error
  | Step_started
  | Step_finished
  | Text_message_start
  | Text_message_content
  | Text_message_end
  | Tool_call_start
  | Tool_call_args
  | Tool_call_end
  | State_snapshot
  | State_delta
  | Custom
[@@deriving show, eq]

let event_type_to_string = function
  | Run_started -> "RUN_STARTED"
  | Run_finished -> "RUN_FINISHED"
  | Run_error -> "RUN_ERROR"
  | Step_started -> "STEP_STARTED"
  | Step_finished -> "STEP_FINISHED"
  | Text_message_start -> "TEXT_MESSAGE_START"
  | Text_message_content -> "TEXT_MESSAGE_CONTENT"
  | Text_message_end -> "TEXT_MESSAGE_END"
  | Tool_call_start -> "TOOL_CALL_START"
  | Tool_call_args -> "TOOL_CALL_ARGS"
  | Tool_call_end -> "TOOL_CALL_END"
  | State_snapshot -> "STATE_SNAPSHOT"
  | State_delta -> "STATE_DELTA"
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
  step_name: string option;
  tool_call_id: string option;
  tool_call_name: string option;
  tool_stream_scope: int option;
  provider_message_id: string option;
  tool_call_block_index: int option;
  snapshot: Yojson.Safe.t option;  (** Full state for STATE_SNAPSHOT *)
  message: string option;          (** Required top-level RUN_ERROR message *)
  code: string option;             (** Optional top-level RUN_ERROR code *)
  custom_name: string option;      (** Custom event name *)
  custom_value: Yojson.Safe.t option;
  timestamp: float;
}

(** Create an event with defaults *)
let make_event ?(timestamp = Time_compat.now ()) ?(run_id=None) ?(message_id=None) ?(role=None)
    ?(delta=None) ?(step_name=None) ?(tool_call_id=None)
    ?(tool_call_name=None) ?(tool_stream_scope=None)
    ?(provider_message_id=None) ?(tool_call_block_index=None) ?(snapshot=None)
    ?(message=None) ?(code=None)
    ?(custom_name=None) ?(custom_value=None)
    ~thread_id event_type =
  (match event_type with
   | Run_error ->
     (match message with
      | Some error_message
        when not (String.equal (String.trim error_message) "") -> ()
      | Some _ | None ->
        invalid_arg "AG-UI RUN_ERROR requires a non-empty top-level message");
     (match custom_name, custom_value with
      | None, None -> ()
      | Some _, _ | _, Some _ ->
        invalid_arg "AG-UI RUN_ERROR cannot use the Custom name/value envelope")
   | ( Run_started
     | Run_finished
     | Step_started
     | Step_finished
     | Text_message_start
     | Text_message_content
     | Text_message_end
     | Tool_call_start
     | Tool_call_args
     | Tool_call_end
     | State_snapshot
     | State_delta
     | Custom ) ->
     (match message, code with
      | None, None -> ()
      | Some _, _ | _, Some _ ->
        invalid_arg "AG-UI message/code fields are valid only for RUN_ERROR"));
  {
    event_type;
    thread_id;
    run_id;
    message_id;
    role;
    delta;
    step_name;
    tool_call_id;
    tool_call_name;
    tool_stream_scope;
    provider_message_id;
    tool_call_block_index;
    snapshot;
    message;
    code;
    custom_name;
    custom_value;
    timestamp;
  }

let run_error ~thread_id ?run_id ~message ?code () =
  make_event
    ~thread_id
    ~run_id
    ~message:(Some message)
    ~code
    Run_error

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
    @ optional "stepName" (fun s -> `String s) e.step_name
    @ optional "toolCallId" (fun s -> `String s) e.tool_call_id
    @ optional "toolCallName" (fun s -> `String s) e.tool_call_name
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
  make_event ?timestamp ~thread_id:default_thread_id
    ~custom_name:(Some name)
    ~custom_value:(Some value)
    Custom

(** Protocol version *)
let protocol_version = "0.1.0"
