(** Explicit schema-to-JSON carrier, not Agent_core.Types.tool_schema.
    The private standalone probe does not load or typecheck Agent_core.
    Some edge fixtures deliberately exceed its admissible schema domain. *)
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
