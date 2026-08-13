(** Canonical event envelope for cross-runtime causality evidence. Event buses,
    durable stores, and adapter boundaries carry this same producer-owned
    identity instead of reconstructing identity from content or timestamps. *)

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
    (** External causation pointer. Private execution events carry typed plural
        causes outside this envelope and require this field to be [None]. *)
  ; source_clock : source_clock
  }

(** Raised when the operating-system entropy source cannot mint an identity.
    Identity creation never falls back to clocks, process IDs, paths, or event
    content. *)
exception Entropy_unavailable of string

(** Generate a producer-owned, cross-process collision-resistant identifier. *)
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
