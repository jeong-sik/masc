(** Current keeper metrics-ledger row identity. Versionless rows are retired
    and must not be decoded by current readers. *)

type kind =
  | Turn
  | Heartbeat

val schema : string
val kind_to_string : kind -> string
val fields : kind -> (string * Yojson.Safe.t) list
val kind_of_json : Yojson.Safe.t -> kind option
