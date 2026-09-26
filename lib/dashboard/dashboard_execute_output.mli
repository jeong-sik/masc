(** Execute output collector for the Code IDE terminal drawer.

    The collector keeps, per keeper, the last completed Execute invocations and
    a numbered log of output events: every line and every task open/close
    marker gets the next sequence number for that keeper. HTTP routes
    serialize an initial snapshot and then keep an SSE tail open that reads
    the log from the subscriber's own position, so a slow viewer neither
    blocks the command that produces output nor loses retained lines. *)

type output_line = {
  seq : int;  (** This line's number in the keeper's output log. *)
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
  last_seq : int;
      (** Newest log number at the time [lines] was read; [0] when the
          keeper has logged nothing. *)
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

val event_log_capacity : int
(** How many of a keeper's most recent output events (lines and task
    open/close markers) the log retains. A subscriber more than this many
    events behind receives one [gap] event naming the numbers it missed,
    then continues from the oldest retained event. *)

val record_completed :
  keeper_name:string ->
  task_id:string option ->
  stdout:string ->
  stderr:string ->
  status:Yojson.Safe.t ->
  ?streamed:bool ->
  unit ->
  unit
(** Record a completed Execute invocation.  When [~streamed:true] its lines
    and task_closed marker were already logged via
    {!append_stream_chunk}/{!record_stream_end}, so this call only records the
    invocation for the snapshot.  Otherwise its lines and a task_closed marker
    are logged here.  Non-cancellation failures are logged and swallowed by
    the implementation because this path is observational. *)

val record_stream_start :
  keeper_name:string -> task_id:string option -> unit
(** Log a [task_opened] marker and bind subsequent chunks to [task_id] until
    [record_stream_end] is called. *)

val append_stream_chunk :
  keeper_name:string -> stream:[ `Stdout | `Stderr ] -> string -> unit
(** Split a live output chunk into lines and log each one. A line longer
    than one row's byte limit continues in the next rows, cut between UTF-8
    characters. Never waits for a subscriber. Empty chunks are ignored. *)

val record_stream_end :
  keeper_name:string -> task_id:string option -> status:Yojson.Safe.t -> unit
(** Log a [task_closed] marker and release the open stream binding. *)

val snapshot : keeper_name:string -> snapshot option
(** Latest retained Execute output for [keeper_name], if any. *)

val event_json : keeper_name:string -> Yojson.Safe.t
(** Build the SSE payload. Returns a [no_task] event when the keeper has no
    retained Execute output. *)

val stream_event_json : stream_event -> Yojson.Safe.t
(** Build an SSE payload for a live tail event: [line], [task_opened] and
    [task_closed] carry their log number in [seq]; [gap] carries
    [missing_from_seq], [missing_to_seq] and [missing_count] for the numbers
    this subscriber can no longer receive. *)

val sse_frame : Yojson.Safe.t -> string
(** Serialize one [event: output] SSE frame. *)

val subscribe : keeper_name:string -> subscriber option
(** Subscribe to events logged for [keeper_name] after this call. Returns
    [None] when the keeper name is empty after normalization. *)

val unsubscribe : subscriber -> unit

val initial_event_json : subscriber -> Yojson.Safe.t
(** The first SSE payload for [subscriber], as {!event_json}. When it is a
    snapshot, the subscriber's live tail continues right after the snapshot's
    [last_seq], so no line appears both in the snapshot and as a live event.
    Call it before the first {!take_event}. *)

val take_event : subscriber -> stream_event
(** Block until the log holds an event after the last one handed to this
    subscriber, then return it. Only one fiber may take from a subscriber. *)

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
