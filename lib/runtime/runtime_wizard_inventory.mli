(** JSON projection of every enabled declared binding, including runtimes whose
    credential or executable is unavailable. Credential values and file paths
    are never projected. Undeclared context limits stay null. *)
val to_json : Runtime_schema.config -> Yojson.Safe.t
