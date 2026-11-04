let event_type = "skill_catalog_published"

let json ~ts_unix = `Assoc [ "type", `String event_type; "ts_unix", `Float ts_unix ]
