(** Canonical event envelope for cross-runtime causality evidence.

    This module is intentionally independent from {!Event_bus}: existing
    event bus envelopes remain backward-compatible, while new code can use
    this richer envelope for durable event streams and adapter boundaries. *)

type source_clock =
  | Wall
  | Monotonic
  | Logical
  | Unknown

type t =
  { event_id : string
  ; correlation_id : string
  ; run_id : string
  ; event_time : float
  ; observed_at : float
  ; seq : int option
  ; parent_event_id : string option
  ; caused_by : string option
    (** Untyped compatibility causation field. Private canonical execution
        events require this to be [None] and carry typed plural causes outside
        this compatibility envelope. *)
  ; source_clock : source_clock
  }

(** Generate a process-local compatibility identifier. OAS's private canonical
    execution writer owns its own typed random identity. *)
val fresh_id : unit -> string

val source_clock_to_string : source_clock -> string
val source_clock_of_string : string -> (source_clock, string) result

val make
  :  ?event_id:string
  -> ?correlation_id:string
  -> ?run_id:string
  -> ?event_time:float
  -> ?observed_at:float
  -> ?seq:int
  -> ?parent_event_id:string
  -> ?caused_by:string
  -> ?source_clock:source_clock
  -> unit
  -> t

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
