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

type event = private {
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
  tool_stream_scope : int option;
  provider_message_id : string option;
  tool_call_block_index : int option;
  snapshot : Yojson.Safe.t option;
      (** Full state for [State_snapshot]. *)
  message : string option;
      (** Required top-level error message for [Run_error]. *)
  code : string option;
      (** Optional top-level error code for [Run_error]. *)
  custom_name : string option;
  custom_value : Yojson.Safe.t option;
  timestamp : float;
}

val make_event :
  ?timestamp:float ->
  ?run_id:string option ->
  ?message_id:string option ->
  ?role:role option ->
  ?delta:string option ->
  ?step_name:string option ->
  ?tool_call_id:string option ->
  ?tool_call_name:string option ->
  ?tool_stream_scope:int option ->
  ?provider_message_id:string option ->
  ?tool_call_block_index:int option ->
  ?snapshot:Yojson.Safe.t option ->
  ?message:string option ->
  ?code:string option ->
  ?custom_name:string option ->
  ?custom_value:Yojson.Safe.t option ->
  thread_id:string ->
  event_type ->
  event
(** Construct an [event] with sensible defaults. [timestamp] defaults to
    [Time_compat.now ()] at call time.

    [Run_error] requires a non-empty [message]. [message] and [code] are
    rejected for every other event type so the Custom [value] envelope cannot
    become a second RUN_ERROR wire contract. *)

val run_error :
  thread_id:string ->
  ?run_id:string ->
  message:string ->
  ?code:string ->
  unit ->
  event
(** Construct a spec-compliant [Run_error] event. This is the concise public
    path for lifecycle failures; Custom [name]/[value] fields are unavailable
    by construction. *)

(** {1 Serialization} *)

val event_to_json : event -> Yojson.Safe.t
(** Spec-compliant JSON with camelCase field names. *)

val event_to_sse : ?id:int -> event -> string
(** Format an event as a single SSE [data:] line followed by [\n\n]. *)

(** {1 MASC → AG-UI Mapping} *)

val default_thread_id : string
(** Thread ID used by the single-namespace MASC bridge (["default"]). *)

val of_custom : ?timestamp:float -> name:string -> Yojson.Safe.t -> event
(** Wrap any MASC event in [Custom] with the given [name]/[value]. *)

(** {1 Protocol Metadata} *)

val protocol_version : string
(** AG-UI protocol version implemented by this bridge. *)
