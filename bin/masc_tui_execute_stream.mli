(** The terminal's side of a Keeper's Execute output stream, without the
    socket.

    [GET /api/v1/dashboard/execute-output/<keeper>] sends a [snapshot] (or
    [no_task]) first on every connection. After it comes one event for each
    thing the Keeper's output log gains: a row ([line]), a command starting
    ([task_opened]) or ending ([task_closed]). Every event carries the next
    number of that log, so a reader that holds the last number it took can tell
    a lost event from a quiet stretch. When the server's ring of events moves
    past a slow reader, the server sends one [gap] naming the numbers it
    dropped.

    A [t] reads the bytes of one connection after another and keeps the
    newest rows, which is what the Terminal tab draws. It has one owner, the
    job that reads the connection, which posts {!view} to the render loop when
    {!version} changes. *)

type line =
  { seq : int  (** This row's number in the Keeper's output log. *)
  ; stream_id : int option
  ; task_id : string option
  ; stream : string
        (** What the server calls the row: [cmd], [stdout], [stderr] or
            [status]. *)
  ; text : string
  }

type active =
  { id : int  (** The stream id of a command that has not ended. *)
  ; task : string option
  ; command : string
  }

type reading =
  { lines : line list  (** Oldest first, at most [capacity] of them. *)
  ; active : active list
        (** Commands that have not ended. One that began after the snapshot is
            named by its first [cmd] row, and left out until that row comes. *)
  ; lines_omitted : int
        (** Rows the server still keeps that this reading does not hold. Rows
            the server has dropped since the snapshot are not counted, which
            is what a new snapshot would say. *)
  ; first_seq : int
        (** The oldest number the server still keeps, as far as this
            connection has followed it. The server's log holds a fixed count of
            numbers, so this moves forward as events arrive. *)
  ; active_count : int
  ; closed : bool
  ; status : Yojson.Safe.t  (** How the last command ended; [`Null] if none has. *)
  ; observed_at : float
        (** When the server last said anything on this connection, a
            keepalive included. *)
  }

type view =
  | Awaiting_first_frame
      (** Nothing was told on this connection or an earlier one. *)
  | Nothing_observed
      (** The server holds no Execute output for this Keeper. *)
  | Observed of reading

type failure =
  | Frame_rejected of string  (** A frame this build cannot read. *)
  | Another_keeper of { expected : string; received : string }
  | Events_lost of { from_seq : int; to_seq : int }
      (** The server dropped these numbers before this reader took them. *)
  | Out_of_order of { expected : int; received : int }

val failure_to_string : failure -> string

type step =
  | Keep_reading
  | Reconnect of failure
      (** Close this connection and open another; its [snapshot] replaces
          what is held. *)

type t

val create : keeper:string -> capacity:int -> t
(** [capacity] is the most rows held. *)

val started : t -> unit
(** A connection was opened. Its bytes start a new frame, and what was held
    stays visible until the new connection's snapshot replaces it. *)

val feed : t -> now:float -> string -> step
(** The next bytes of the connection, in any chunking. [now] is when they
    arrived. *)

val view : t -> view

val version : t -> int
(** Changes whenever {!view} may have changed, so a job can post only then. *)

val synchronized : t -> bool
(** The current connection has supplied an accepted initial frame. Reset by
    {!started} and by a rejected frame; retained output is not evidence. *)
