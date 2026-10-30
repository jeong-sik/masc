type source =
  | Builtin
  | Attached of
      { provider_id : string
      ; endpoint : string
      ; remote_name : string
      }

type entry =
  { source : source
  ; schema_json : Yojson.Safe.t
  }
