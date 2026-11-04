let event_type = "keeper_skill_activations_changed"

let json ~name ~trace_id ~ts_unix =
  `Assoc
    [ "type", `String event_type
    ; "name", `String name
    ; "trace_id", `String trace_id
    ; "ts_unix", `Float ts_unix
    ]
