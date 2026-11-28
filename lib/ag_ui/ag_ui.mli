(** AG-UI Protocol — Agent-User Interface Event Bridge.

    Translates MASC internal events to the AG-UI protocol format
    (CopilotKit standard). AG-UI sits at Layer 1 (Agent↔User),
    complementing MCP (Layer 2) and A2A (Layer 3).

    @see <https://docs.ag-ui.com/concepts/events>
    @since 2.60.0 *)

(** {1 Event Types} *)

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
  tool_call_id : string option;
  tool_call_name : string option;
  text_response : text_response;
      (** Complete observed response or explicitly unobserved scope; independent of tool occurrence scope. *)
  tool_stream_scope : int option;
  provider_message_id : string option;
  tool_call_block_index : int option;
  snapshot : Yojson.Safe.t option;
      (** Accumulated tool-call arguments for [Tool_call_args]. *)
  message : string option;
      (** Required top-level error message for [Run_error]. *)
  code : string option;
      (** Optional top-level error code for [Run_error]. *)
  custom_name : string option;
  custom_value : Yojson.Safe.t option;
  timestamp : float;
}

(** {1 Constructors}

    One constructor per frame kind. Each takes only the fields that kind
    carries on the wire (lib/keeper_chat_wire/keeper_chat_wire.atd), so a
    frame without a required field cannot be built. [timestamp] defaults to
    [Time_compat.now ()] at call time. *)

type tool_stream_occurrence =
  { stream_scope : int
  ; provider_message_id : string option
  ; block_index : int
  }
(** The streamed tool call a [TOOL_CALL_*] frame names. *)

type tool_call_arguments =
  | Arguments_delta of string
  | Arguments_snapshot of string
      (** The whole arguments text so far, sent as a JSON string. *)

val run_started :
  ?timestamp:float -> thread_id:string -> run_id:string -> unit -> event

val run_finished :
  ?timestamp:float -> thread_id:string -> run_id:string -> unit -> event

val run_error :
  ?timestamp:float ->
  thread_id:string ->
  ?run_id:string ->
  message:string ->
  ?code:string ->
  unit ->
  event
(** @raise Invalid_argument when [message] is blank. *)

val text_message_start :
  ?timestamp:float ->
  thread_id:string ->
  ?run_id:string ->
  message_id:string ->
  role:role ->
  unit ->
  event

val text_message_content :
  ?timestamp:float ->
  thread_id:string ->
  ?run_id:string ->
  ?message_id:string ->
  ?text_response:text_response ->
  delta:string ->
  unit ->
  event
(** [text_response] defaults to [Unobserved_scope None]. *)

val text_message_end :
  ?timestamp:float ->
  thread_id:string ->
  ?run_id:string ->
  ?message_id:string ->
  unit ->
  event

val tool_call_start :
  ?timestamp:float ->
  thread_id:string ->
  ?run_id:string ->
  ?tool_call_id:string ->
  tool_call_name:string ->
  tool_stream_occurrence ->
  event

val tool_call_args :
  ?timestamp:float ->
  thread_id:string ->
  ?run_id:string ->
  ?tool_call_id:string ->
  tool_stream_occurrence ->
  tool_call_arguments ->
  event

val tool_call_end :
  ?timestamp:float ->
  thread_id:string ->
  ?run_id:string ->
  ?tool_call_id:string ->
  tool_stream_occurrence ->
  event

val custom :
  ?timestamp:float ->
  thread_id:string ->
  ?run_id:string ->
  name:string ->
  Yojson.Safe.t ->
  event
(** A [CUSTOM] frame. [name] says what the value holds. *)

(** {1 Serialization} *)

val event_to_json : event -> Yojson.Safe.t
(** Spec-compliant JSON with camelCase field names. *)

val event_to_sse : ?id:int -> event -> string
(** Format an event as a single SSE [data:] line followed by [\n\n]. *)

(** {1 MASC → AG-UI Mapping} *)

val default_thread_id : string
(** Thread ID used by the single-namespace MASC bridge (["default"]). *)

val of_custom : ?timestamp:float -> name:string -> Yojson.Safe.t -> event
(** {!custom} on {!default_thread_id} without a run. *)

(** {1 Protocol Metadata} *)

val protocol_version : string
(** AG-UI protocol version implemented by this bridge. *)
