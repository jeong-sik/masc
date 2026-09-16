(** Canonical Server-Sent Events wire framing. *)

val format_event : ?id:int -> ?event_type:string -> string -> string
(** Frame a text payload. Each logical payload line receives its own [data:]
    field; optional replay identity and event type precede the payload. *)

val format_event_yojson :
  ?id:int -> ?event_type:string -> Yojson.Safe.t -> string
(** Frame JSON without allocating an intermediate serialized JSON string. *)

(** A JSON value with its compact encoding. Encoding a large value is most of
    the cost of broadcasting it, so a caller can encode once, off its fiber,
    and hand the result on. Only {!encode_json} and {!encoded_object} make one,
    so [text] is always the encoding of [json]. *)
type encoded_json = private
  { json : Yojson.Safe.t
  ; text : string  (** Compact JSON; it holds no line break. *)
  }

val encode_json : Yojson.Safe.t -> encoded_json

val encoded_object : (string * encoded_json) list -> encoded_json
(** The object of these fields. Its text joins the fields' texts without
    encoding them again, and is the same bytes {!encode_json} writes for the
    whole object. *)

val format_event_encoded : ?id:int -> ?event_type:string -> encoded_json -> string
(** {!format_event_yojson} of [encoded.json], written from [encoded.text]. *)

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
