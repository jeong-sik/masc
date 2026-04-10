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

(** AG-UI event types — subset relevant to MASC agent coordination *)
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
  snapshot: Yojson.Safe.t option;  (** Full state for STATE_SNAPSHOT *)
  custom_name: string option;      (** Custom event name *)
  custom_value: Yojson.Safe.t option;
  timestamp: float;
}

(** Create an event with defaults *)
let make_event ?(run_id=None) ?(message_id=None) ?(role=None)
    ?(delta=None) ?(step_name=None) ?(tool_call_id=None)
    ?(tool_call_name=None) ?(snapshot=None)
    ?(custom_name=None) ?(custom_value=None)
    ~thread_id event_type =
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
    snapshot;
    custom_name;
    custom_value;
    timestamp = Time_compat.now ();
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
    @ optional "stepName" (fun s -> `String s) e.step_name
    @ optional "toolCallId" (fun s -> `String s) e.tool_call_id
    @ optional "toolCallName" (fun s -> `String s) e.tool_call_name
    @ optional "snapshot" (fun j -> j) e.snapshot
    @ optional "name" (fun s -> `String s) e.custom_name
    @ optional "value" (fun j -> j) e.custom_value)

(** Format as SSE data line *)
let event_to_sse (e : event) : string =
  let json = event_to_json e |> Yojson.Safe.to_string in
  Printf.sprintf "data: %s\n\n" json

(* ---------- MASC → AG-UI Event Mapping ---------- *)

(** Default thread ID for the single-namespace AG-UI bridge. *)
let default_thread_id = "default"

(** Map MASC agent_joined to AG-UI RUN_STARTED *)
let of_agent_joined ~agent_name : event =
  make_event ~thread_id:default_thread_id
    ~run_id:(Some agent_name)
    ~custom_name:(Some "AGENT_JOINED")
    ~custom_value:(Some (`Assoc [("agent", `String agent_name)]))
    Run_started

(** Map MASC agent_left to AG-UI RUN_FINISHED *)
let of_agent_left ~agent_name : event =
  make_event ~thread_id:default_thread_id
    ~run_id:(Some agent_name)
    ~custom_name:(Some "AGENT_LEFT")
    ~custom_value:(Some (`Assoc [("agent", `String agent_name)]))
    Run_finished

(** Map MASC broadcast message to AG-UI text message sequence.
    Returns a list of 3 events: START, CONTENT, END *)
let of_broadcast ~agent_name ~message ~message_id : event list =
  let thread_id = default_thread_id in
  let mid = Some message_id in
  [
    make_event ~thread_id ~run_id:(Some agent_name)
      ~message_id:mid ~role:(Some Assistant)
      Text_message_start;
    make_event ~thread_id ~run_id:(Some agent_name)
      ~message_id:mid ~delta:(Some message)
      Text_message_content;
    make_event ~thread_id ~run_id:(Some agent_name)
      ~message_id:mid
      Text_message_end;
  ]

(** Map MASC task claim to AG-UI STEP_STARTED *)
let of_task_claimed ~agent_name ~task_id : event =
  make_event ~thread_id:default_thread_id
    ~run_id:(Some agent_name)
    ~step_name:(Some task_id)
    Step_started

(** Map MASC task done to AG-UI STEP_FINISHED *)
let of_task_done ~agent_name ~task_id : event =
  make_event ~thread_id:default_thread_id
    ~run_id:(Some agent_name)
    ~step_name:(Some task_id)
    Step_finished

(** Map MASC tool call to AG-UI TOOL_CALL_START *)
let of_tool_call ~agent_name ~tool_name ~call_id ~args_json : event list =
  let thread_id = default_thread_id in
  [
    make_event ~thread_id ~run_id:(Some agent_name)
      ~tool_call_id:(Some call_id)
      ~tool_call_name:(Some tool_name)
      Tool_call_start;
    make_event ~thread_id ~run_id:(Some agent_name)
      ~tool_call_id:(Some call_id)
      ~delta:(Some args_json)
      Tool_call_args;
    make_event ~thread_id ~run_id:(Some agent_name)
      ~tool_call_id:(Some call_id)
      Tool_call_end;
  ]

(** Map MASC room state to AG-UI STATE_SNAPSHOT *)
let of_room_state (state : Yojson.Safe.t) : event =
  make_event ~thread_id:default_thread_id
    ~snapshot:(Some state)
    State_snapshot

(** Map any MASC-specific event to AG-UI CUSTOM *)
let of_custom ~name (value : Yojson.Safe.t) : event =
  make_event ~thread_id:default_thread_id
    ~custom_name:(Some name)
    ~custom_value:(Some value)
    Custom

(** Map MASC task_update JSON to appropriate AG-UI event.
    Inspects the "status" field to determine the event type. *)
let of_task_update (task_json : Yojson.Safe.t) : event =
  let task_id = Safe_ops.json_string ~default:"unknown" "id" task_json in
  let status = Safe_ops.json_string ~default:"" "status" task_json in
  let agent = Safe_ops.json_string ~default:"unknown" "agent" task_json in
  match status with
  | "claimed" ->
    of_task_claimed ~agent_name:agent ~task_id
  | "done" ->
    of_task_done ~agent_name:agent ~task_id
  | _ ->
    of_custom
      ~name:"TASK_UPDATE"
      (`Assoc [
        ("taskId", `String task_id);
        ("status", `String status);
        ("agent", `String agent);
      ])

(** Protocol version *)
let protocol_version = "0.1.0"
