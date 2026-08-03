(** Canonical Server-Sent Events wire framing. *)

val format_event : ?id:int -> ?event_type:string -> string -> string
(** Frame a text payload. Each logical payload line receives its own [data:]
    field; optional replay identity and event type precede the payload. *)

val format_event_yojson :
  ?id:int -> ?event_type:string -> Yojson.Safe.t -> string
(** Frame JSON without allocating an intermediate serialized JSON string. *)
