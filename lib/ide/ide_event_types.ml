(** IDE Event Types — unified event model for Keeper activity visualization. *)

type ide_event =
  | Tool_event of tool_event
  | Turn_event of turn_event

and tool_event =
  { tool_name : string
  ; keeper_id : string
  ; turn_id : string
  ; outcome : string
  ; typed_outcome : string
  ; latency_ms : int
  ; summary : string
  ; file_path : string option
  ; timestamp_ms : int64
  }

and turn_event =
  { turn_id : string
  ; keeper_id : string
  ; phase : string
  ; model_used : string option
  ; tools_used : string list
  ; stop_reason : string option
  ; duration_ms : int option
  ; timestamp_ms : int64
  }

let tool_event_to_json (e : tool_event) : Yojson.Safe.t =
  `Assoc
    [ "type", `String "tool"
    ; "tool_name", `String e.tool_name
    ; "keeper_id", `String e.keeper_id
    ; "turn_id", `String e.turn_id
    ; "outcome", `String e.outcome
    ; "typed_outcome", `String e.typed_outcome
    ; "latency_ms", `Int e.latency_ms
    ; "summary", `String e.summary
    ; "file_path", (match e.file_path with Some fp -> `String fp | None -> `Null)
    ; "timestamp_ms", `Intlit (Int64.to_string e.timestamp_ms)
    ]

let turn_event_to_json (e : turn_event) : Yojson.Safe.t =
  `Assoc
    [ "type", `String "turn"
    ; "turn_id", `String e.turn_id
    ; "keeper_id", `String e.keeper_id
    ; "phase", `String e.phase
    ; "model_used", (match e.model_used with Some m -> `String m | None -> `Null)
    ; "tools_used", `List (List.map (fun s -> `String s) e.tools_used)
    ; "stop_reason", (match e.stop_reason with Some r -> `String r | None -> `Null)
    ; "duration_ms", (match e.duration_ms with Some d -> `Int d | None -> `Null)
    ; "timestamp_ms", `Intlit (Int64.to_string e.timestamp_ms)
    ]

let ide_event_to_json = function
  | Tool_event e -> tool_event_to_json e
  | Turn_event e -> turn_event_to_json e
