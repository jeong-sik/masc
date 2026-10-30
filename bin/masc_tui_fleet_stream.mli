(** The terminal's side of the fleet stream (RFC-0477), without the socket.

    A [t] reads the bytes of one connection after another and says what the
    Keepers screen can draw. It has one owner, the job that reads the
    connection, which posts {!view} to the render loop whenever it changes.

    The stream sends a [Snapshot] or [Unavailable_snapshot] first on every
    connection, then one event per revision. Either snapshot is always taken,
    because a restarted server numbers
    from 1 again. Any other event must carry the revision after the last one;
    when it does not, an event was lost, and {!feed} asks for a new connection,
    whose [Snapshot] replaces everything. *)

type reading =
  { revision : Masc.Fleet_stream.Revision.t
  ; measured_at : float
  ; fleet : Masc.Fleet_stream.fleet
  ; degraded : Masc.Fleet_stream.degradation option
  }
(** What the server last told. [measured_at] is the scan that made the last
    event. A scan that finds the same fleet makes no event, so it can be older
    than the server's latest scan. *)

type trouble =
  | Scans_failing of Masc.Fleet_stream.degradation
      (** The connection is fine and the server's fleet scans are not. *)
  | Disconnected of { since : float }
      (** The connection is down. The reading is what it told before. *)

type failure =
  | Refused of { status : int; detail : string }
  | Schema_mismatch of { expected : int; received : int }
  | Frame_rejected of string  (** A frame this build cannot read. *)

type view =
  | Awaiting_first_reading
      (** Nothing was told yet and no connection has been lost. *)
  | Unreachable of { since : float }
      (** Nothing was ever told, and the connection is down since [since]:
          the stream could not be reached, which is not the wait for the first
          scan. It lasts until a connection delivers a [Snapshot] or an
          [Unavailable_snapshot]. *)
  | Reading of { reading : reading; trouble : trouble option }
  | Unavailable of
      { degradation : Masc.Fleet_stream.degradation
      ; disconnected_since : float option
      }
      (** A scan failed before any reading. No fleet counts were observed.
          A later connection loss is retained separately from the scan failure. *)
  | Cannot_read of failure
      (** No usable reading: the server refused, or speaks a form this build
          does not. It lasts until a connection delivers a [Snapshot] or an
          [Unavailable_snapshot]. *)

type t

val create : unit -> t

val started : t -> unit
(** A connection was opened. Its bytes start a new frame; the last observation
    and any connection loss remain visible until the new snapshot. *)

type step =
  | Keep_reading
  | Reconnect  (** Close this connection and open another. *)

val feed : t -> string -> step
(** The next bytes of the connection, in any chunking. *)

val refused : t -> status:int -> detail:string -> unit
(** The server answered with an HTTP refusal instead of the stream. *)

val lost : t -> now:float -> unit
(** The connection ended, whatever the reason. The first loss after a state
    (or since the start) fixes [since]; the losses after it, while no new
    state arrived, keep it. *)

val view : t -> view
