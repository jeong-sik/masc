type frame = { id : string option; data : string }
type decoder
val create_decoder : unit -> decoder
val feed : decoder -> string -> frame list
(** Complete events from arbitrary byte chunks. Supports LF/CRLF/CR, an initial
    BOM, and joined data fields. Unterminated EOF events are not emitted.
    [id] is the explicit field of this frame, not a persisted reconnect cursor. *)

val data_payload_line : string -> string option
(** Read one SSE data field, stripping one optional space after the colon and
    a trailing CR. Bare [data] is an empty field; other fields are ignored. *)

val data_payloads_of_stream : string -> string list
(** Payloads of complete blank-line-terminated events in a buffered UTF-8
    stream. Joins data fields with LF, accepts LF/CRLF/CR and an initial BOM,
    and discards an unterminated event at EOF. Event/id/retry fields are not
    projected by this payload-only reader. *)

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
type observer_reset = Instance_changed | Unscoped_cursor | Cursor_ahead
type observer_replay =
  | Fresh
  | Resumed  (** No event after the cursor left the retained window. *)
  | Resumed_after_gap of { missed_through : int }
      (** The window dropped events up to [missed_through], past the cursor.
          The replay holds what is left after it. *)
  | Reset of observer_reset
type observer_handshake = { instance_id : string; replay : observer_replay }
(** [instance_id] is a nonempty HTTP token; the server uses a UUIDv7. *)

val observer_cursor_headers : observer_cursor option -> (string * string) list
(** Send a numeric cursor only with the process instance that delivered it. *)

val negotiate_observer :
  instance_id:string ->
  current_event_id:int ->
  headers:(string * string) list ->
  last_event_id:int option ->
  observer_handshake * int option
(** The returned cursor is the only cursor suitable for both registration and
    replay. A cursor from another or unspecified instance, or ahead of the
    current process counter, is discarded before either path can suppress
    new events. [Fresh] and [Reset] start live only.
    Repeated instance headers are unscoped even when their values agree.
    [Resumed] reads the retained replay window; whether events after the
    cursor expired from it is known only after the replay is read, and
    {!observer_after_replay} records it. *)

val observer_after_replay :
  observer_handshake -> missed_through:int option -> observer_handshake
(** A [Resumed] handshake becomes [Resumed_after_gap] when the replay found
    events dropped past the cursor. Any other handshake is unchanged. *)

val observer_response_headers : observer_handshake -> (string * string) list

val decode_observer_response :
  (string * string) list -> (observer_handshake option, string) result
(** [Ok None] means the peer did not advertise scoped replay. Partial or invalid
    metadata, including duplicate or contradictory headers, is an error, never
    an assumed continuation of a previous epoch. *)

type observer_validation_error =
  | Retry_without_cursor of observer_cursor * string
  | Invalid_observer_response of string

val validate_observer_response :
  cursor:observer_cursor option -> (string * string) list ->
  (observer_handshake option, observer_validation_error) result
(** Validate response metadata against the cursor actually requested.
    An unadvertised capability is usable only without a requested cursor;
    a resumed stream must name that cursor's instance and a gap must pass it.
    Fresh and reset responses must also be consistent with the request. Missing,
    malformed, or unscoped replay metadata rejects the current stream and asks
    the caller to discard only the named cursor before retrying. A successful
    retry without replay cannot recover events missed while disconnected. *)
