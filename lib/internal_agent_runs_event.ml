let event_type = "internal_agent_runs_changed"
let to_json () = `Assoc [ ("type", `String event_type) ]
