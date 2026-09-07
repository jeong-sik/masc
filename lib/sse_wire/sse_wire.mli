(** Canonical Server-Sent Events wire framing. *)

val format_event : ?id:int -> ?event_type:string -> string -> string
(** Frame a text payload. Each logical payload line receives its own [data:]
    field; optional replay identity and event type precede the payload. *)

val format_event_yojson :
  ?id:int -> ?event_type:string -> Yojson.Safe.t -> string
(** Frame JSON without allocating an intermediate serialized JSON string. *)

type observer_cursor = { instance_id : string; event_id : int }
type observer_reset = Instance_changed | Unscoped_cursor
type observer_replay = Fresh | Resumed | Reset of observer_reset
type observer_handshake = { instance_id : string; replay : observer_replay }

val observer_cursor_headers : observer_cursor option -> (string * string) list
(** Send a numeric cursor only with the process instance that delivered it. *)

val negotiate_observer :
  instance_id:string ->
  headers:(string * string) list ->
  last_event_id:int option ->
  observer_handshake * int option
(** The returned cursor is the only cursor suitable for both registration and
    replay. A cursor from another or unspecified instance is discarded before
    either path can suppress new events. [Fresh] and [Reset] start live only.
    [Resumed] reads the retained replay window; it does not prove that no events
    have expired from that window. *)

val observer_response_headers : observer_handshake -> (string * string) list

val decode_observer_response :
  (string * string) list -> (observer_handshake option, string) result
(** [Ok None] means the peer did not advertise scoped replay. Partial or invalid
    metadata is an error, never an assumed continuation of a previous epoch. *)
