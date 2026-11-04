(** A connector's state changed: its bindings, its recorded names, or what the
    connector list draws from its connection. It names the connector and
    carries nothing else; a reader that shows connectors
    ([GET /api/v1/gate/connectors], [GET /api/v1/gate/connector/names]) reads
    that connector again. *)

val event_type : string

val json : connector:string -> ts_unix:float -> Yojson.Safe.t
