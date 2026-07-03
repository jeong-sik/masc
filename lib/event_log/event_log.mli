(** Event_log — single canonical event stream for MASC.

    P2-2 foundation: a time-ordered, uniquely identified in-memory event
    log that REST, SSE, and the keeper event bus can all publish into.
    JSONL persistence and subscriber fan-out are deliberate follow-ups. *)

type source = string
(** Publisher tag, e.g. ["rest"], ["sse"], ["event_bus"], ["tool_call"]. *)

type event_id = string
(** Canonical event identifier. Lexicographically sortable and unique:
    [<unix-ms>_<uuidv4>]. *)

type event =
  { id : event_id
  ; ts_unix : float
  ; source : source
  ; kind : string
  ; payload : Yojson.Safe.t
  }
(** A single canonical event record. *)

val publish : source:source -> kind:string -> Yojson.Safe.t -> event_id
(** Append an event to the log and return its canonical id. Thread-safe
    under Eio. *)

val recent : ?since_id:event_id -> int -> event list
(** Return the [n] most recent events, newest first. If [since_id] is
    provided, skip events newer than it and return the next [n]
    (pagination-style). *)

val to_json : event -> Yojson.Safe.t
(** Serialize an event to JSON. *)

module For_testing : sig
  val reset : unit -> unit
  (** Clear the in-memory log. Only for test isolation. *)

  val capacity : int
  (** Maximum number of events retained. Equals the internal ring size;
      exposed so boundary tests reference the single capacity constant
      instead of duplicating the literal. *)
end
