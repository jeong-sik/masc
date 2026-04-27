(** AG-UI Protocol — Agent-User Interface Event Bridge.

    Translates MASC internal events to the AG-UI protocol format
    (CopilotKit standard). AG-UI sits at Layer 1 (Agent↔User),
    complementing MCP (Layer 2) and A2A (Layer 3).

    @see <https://docs.ag-ui.com/concepts/events>
    @since 2.60.0 *)

(** {1 Event Types} *)

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

val event_type_to_string : event_type -> string
(** Spec-compliant uppercase string (e.g. ["RUN_STARTED"]). *)

(** {1 Message Role} *)

type role = User | Assistant | System | Tool
[@@deriving show, eq]

val role_to_string : role -> string
(** Spec-compliant lowercase string (e.g. ["assistant"]). *)

(** {1 Event Record} *)

type event = {
  event_type : event_type;
  thread_id : string;
  run_id : string option;
  message_id : string option;
  role : role option;
  delta : string option;
      (** Text chunk or tool args fragment. *)
  step_name : string option;
  tool_call_id : string option;
  tool_call_name : string option;
  snapshot : Yojson.Safe.t option;
      (** Full state for [State_snapshot]. *)
  custom_name : string option;
  custom_value : Yojson.Safe.t option;
  timestamp : float;
}

val make_event :
  ?run_id:string option ->
  ?message_id:string option ->
  ?role:role option ->
  ?delta:string option ->
  ?step_name:string option ->
  ?tool_call_id:string option ->
  ?tool_call_name:string option ->
  ?snapshot:Yojson.Safe.t option ->
  ?custom_name:string option ->
  ?custom_value:Yojson.Safe.t option ->
  thread_id:string ->
  event_type ->
  event
(** Construct an [event] with sensible defaults. [timestamp] is set to
    [Time_compat.now ()] at call time. *)

(** {1 Serialization} *)

val event_to_json : event -> Yojson.Safe.t
(** Spec-compliant JSON with camelCase field names. *)

val event_to_sse : event -> string
(** Format an event as a single SSE [data:] line followed by [\n\n]. *)

(** {1 MASC → AG-UI Mapping} *)

val default_thread_id : string
(** Thread ID used by the single-namespace MASC bridge (["default"]). *)

val of_agent_joined : agent_name:string -> event
(** [agent_joined] → [Run_started] with [custom_name="AGENT_JOINED"]. *)

val of_agent_left : agent_name:string -> event
(** [agent_left] → [Run_finished] with [custom_name="AGENT_LEFT"]. *)

val of_broadcast :
  agent_name:string -> message:string -> message_id:string -> event list
(** Broadcast → 3 events: [Text_message_start], [Text_message_content]
    (with [delta=message]), [Text_message_end]. *)

val of_task_claimed : agent_name:string -> task_id:string -> event
(** Task claim → [Step_started] with [step_name=task_id]. *)

val of_task_done : agent_name:string -> task_id:string -> event
(** Task done → [Step_finished] with [step_name=task_id]. *)

val of_tool_call :
  agent_name:string ->
  tool_name:string ->
  call_id:string ->
  args_json:string ->
  event list
(** Tool call → 3 events: [Tool_call_start], [Tool_call_args]
    (with [delta=args_json]), [Tool_call_end]. *)

val of_room_state : Yojson.Safe.t -> event
(** Room snapshot → [State_snapshot]. *)

val of_custom : name:string -> Yojson.Safe.t -> event
(** Wrap any MASC event in [Custom] with the given [name]/[value]. *)

val of_task_update : Yojson.Safe.t -> event
(** Inspect [status] in the task JSON: ["claimed"] → {!of_task_claimed},
    ["done"] → {!of_task_done}, else [Custom] with [name="TASK_UPDATE"]. *)

(** {1 Protocol Metadata} *)

val protocol_version : string
(** AG-UI protocol version implemented by this bridge. *)
