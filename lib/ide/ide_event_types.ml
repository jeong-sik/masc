(** IDE Event Types — unified event model for Keeper activity visualization.

    Captures tool call outcomes, PR operations, comments, and turn context
    as structured events that flow from the Keeper/Tool layer to the IDE layer.
    Events are stored in partition-scoped JSONL files under [.masc-ide/]. *)

(** {1 Event Variants} *)

type ide_event =
  | Region_event of region_event
  | Tool_event of tool_event
  | Pr_event of pr_event
  | Comment_event of comment_event
  | Turn_event of turn_event

and region_event =
  { file_path : string
  ; line_start : int
  ; line_end : int
  ; keeper_id : string
  ; tool_name : string
  ; turn_id : string
  ; outcome : string (** "success" | "failure" *)
  ; timestamp_ms : int64
  }

and tool_event =
  { tool_name : string
  ; keeper_id : string
  ; turn_id : string
  ; outcome : string (** "success" | "failure" *)
  ; typed_outcome : string (** "progress" | "no_progress" | "error" *)
  ; latency_ms : int
  ; summary : string (** first 200 chars of tool output *)
  ; file_path : string option (** related file, if any *)
  ; timestamp_ms : int64
  }

and pr_event =
  { pr_number : int
  ; pr_url : string
  ; pr_title : string
  ; pr_state : string (** "open" | "closed" | "merged" *)
  ; repo : string
  ; keeper_id : string
  ; turn_id : string
  ; comment_count : int
  ; review_status : string option
  ; timestamp_ms : int64
  }

and comment_event =
  { comment_id : string
  ; pr_number : int option
  ; board_post_id : string option
  ; author : string
  ; content : string
  ; keeper_id : string
  ; turn_id : string
  ; timestamp_ms : int64
  }

and turn_event =
  { turn_id : string
  ; keeper_id : string
  ; phase : string (** "started" | "completed" | "failed" *)
  ; model_used : string option
  ; tools_used : string list
  ; stop_reason : string option
  ; duration_ms : int option
  ; timestamp_ms : int64
  }

(** {1 JSON Serialization} *)

let region_event_to_json (e : region_event) : Yojson.Safe.t =
  `Assoc
    [ "type", `String "region"
    ; "file_path", `String e.file_path
    ; "line_start", `Int e.line_start
    ; "line_end", `Int e.line_end
    ; "keeper_id", `String e.keeper_id
    ; "tool_name", `String e.tool_name
    ; "turn_id", `String e.turn_id
    ; "outcome", `String e.outcome
    ; "timestamp_ms", `Intlit (Int64.to_string e.timestamp_ms)
    ]

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

let pr_event_to_json (e : pr_event) : Yojson.Safe.t =
  `Assoc
    [ "type", `String "pr"
    ; "pr_number", `Int e.pr_number
    ; "pr_url", `String e.pr_url
    ; "pr_title", `String e.pr_title
    ; "pr_state", `String e.pr_state
    ; "repo", `String e.repo
    ; "keeper_id", `String e.keeper_id
    ; "turn_id", `String e.turn_id
    ; "comment_count", `Int e.comment_count
    ; "review_status", (match e.review_status with Some s -> `String s | None -> `Null)
    ; "timestamp_ms", `Intlit (Int64.to_string e.timestamp_ms)
    ]

let comment_event_to_json (e : comment_event) : Yojson.Safe.t =
  `Assoc
    [ "type", `String "comment"
    ; "comment_id", `String e.comment_id
    ; "pr_number", (match e.pr_number with Some n -> `Int n | None -> `Null)
    ; "board_post_id", (match e.board_post_id with Some id -> `String id | None -> `Null)
    ; "author", `String e.author
    ; "content", `String (if String.length e.content > 500 then String.sub e.content 0 500 ^ "..." else e.content)
    ; "keeper_id", `String e.keeper_id
    ; "turn_id", `String e.turn_id
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
  | Region_event e -> region_event_to_json e
  | Tool_event e -> tool_event_to_json e
  | Pr_event e -> pr_event_to_json e
  | Comment_event e -> comment_event_to_json e
  | Turn_event e -> turn_event_to_json e

let ide_event_to_string (e : ide_event) : string =
  Yojson.Safe.to_string (ide_event_to_json e)
