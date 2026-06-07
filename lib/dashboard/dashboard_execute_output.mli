(** Execute output collector for the Code IDE terminal drawer.

    The collector stores completed Execute output per keeper in bounded,
    in-process rings. HTTP routes serialize an initial snapshot and can then
    keep an SSE tail open for later line events. *)

type output_line = {
  ts_ms : int;
  stream : string;
  text : string;
  ansi : bool;
}

type snapshot = {
  keeper : string;
  task_id : string option;
  task_count : int;
  lines : output_line list;
  stdout_since : string;
  stderr_since : string;
  since_stdout : int;
  since_stderr : int;
  bytes_dropped_stdout : int;
  bytes_dropped_stderr : int;
  closed : bool;
  status : Yojson.Safe.t option;
  generated_at : float;
}

type stream_event
type subscriber

val record_completed :
  keeper_name:string ->
  task_id:string option ->
  stdout:string ->
  stderr:string ->
  status:Yojson.Safe.t ->
  ?streamed:bool ->
  unit ->
  unit
(** Record a completed Execute invocation.  When [~streamed:true] the line and
    task_closed events have already been emitted via
    {!append_stream_chunk}/{!record_stream_end}, so this call only updates the
    retained snapshot.  Non-cancellation failures are logged and swallowed by
    the implementation because this path is observational. *)

val record_stream_start :
  keeper_name:string -> task_id:string option -> unit
(** Emit a [task_opened] event to current subscribers and bind subsequent
    chunks to [task_id] until [record_stream_end] is called. *)

val append_stream_chunk :
  keeper_name:string -> stream:[ `Stdout | `Stderr ] -> string -> unit
(** Append a live output chunk, split it into lines, and broadcast [line]
    events to current subscribers. Empty chunks are ignored. *)

val record_stream_end :
  keeper_name:string -> task_id:string option -> status:Yojson.Safe.t -> unit
(** Emit a [task_closed] event to current subscribers and release the open
    stream binding. *)

val snapshot : keeper_name:string -> snapshot option
(** Latest retained Execute output for [keeper_name], if any. *)

val event_json : keeper_name:string -> Yojson.Safe.t
(** Build the SSE payload. Returns a [no_task] event when the keeper has no
    retained Execute output. *)

val stream_event_json : stream_event -> Yojson.Safe.t
(** Build an SSE payload for a live tail event. *)

val sse_frame : Yojson.Safe.t -> string
(** Serialize one [event: output] SSE frame. *)

val subscribe : keeper_name:string -> subscriber option
(** Subscribe to future line events for [keeper_name]. Returns [None] when the
    keeper name is empty after normalization. *)

val unsubscribe : subscriber -> unit

val take_event : subscriber -> stream_event
(** Block until the next live tail event for this subscriber. *)

(** {1 Test hooks} *)

val reset_for_testing : unit -> unit

val output_lines_for_testing : keeper_name:string -> output_line list

val inject_for_testing :
  keeper_name:string ->
  ?task_id:string ->
  ?generated_at:float ->
  stdout:string ->
  stderr:string ->
  status:Yojson.Safe.t ->
  unit ->
  unit
