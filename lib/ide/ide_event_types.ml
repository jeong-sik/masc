(** IDE Event Types — unified event model for Keeper activity visualization. *)

(** Structured descriptor for what a shell command did.
    Computed from Shell IR GADT by the Execute handler.
    Consumed by the bridge for deterministic event generation. *)
type command_descriptor =
  | Gh_pr_create of { title : string; base : string; draft : bool }
  | Gh_pr_merge of { pr_number : int; squash : bool }
  | Gh_pr_comment of { pr_number : int; body : string }
  | Gh_pr_close of { pr_number : int }
  | Gh_pr_edit of { pr_number : int; title : string option }
  | Gh_pr_review of { pr_number : int }
  | Gh_issue_create of { title : string; body : string }
  | Gh_issue_close of { issue_number : int }
  | Git_push of { remote : string; branch : string; force : bool }
  | Git_commit of { message : string }
  | Gh_api_pr_create of { repo : string; title : string; base : string }
  | Gh_api_pr_merge of { repo : string; pr_number : int }
  | Gh_api_pr_comment of { repo : string; pr_number : int; body : string }
  | Generic

let command_descriptor_to_json = function
  | Gh_pr_create { title; base; draft } ->
    `Assoc [ "kind", `String "gh_pr_create"; "title", `String title; "base", `String base; "draft", `Bool draft ]
  | Gh_pr_merge { pr_number; squash } ->
    `Assoc [ "kind", `String "gh_pr_merge"; "pr_number", `Int pr_number; "squash", `Bool squash ]
  | Gh_pr_comment { pr_number; body } ->
    `Assoc [ "kind", `String "gh_pr_comment"; "pr_number", `Int pr_number; "body", `String body ]
  | Gh_pr_close { pr_number } ->
    `Assoc [ "kind", `String "gh_pr_close"; "pr_number", `Int pr_number ]
  | Gh_pr_edit { pr_number; title } ->
    `Assoc [ "kind", `String "gh_pr_edit"; "pr_number", `Int pr_number; "title", (match title with Some t -> `String t | None -> `Null) ]
  | Gh_pr_review { pr_number } ->
    `Assoc [ "kind", `String "gh_pr_review"; "pr_number", `Int pr_number ]
  | Gh_issue_create { title; body } ->
    `Assoc [ "kind", `String "gh_issue_create"; "title", `String title; "body", `String body ]
  | Gh_issue_close { issue_number } ->
    `Assoc [ "kind", `String "gh_issue_close"; "issue_number", `Int issue_number ]
  | Git_push { remote; branch; force } ->
    `Assoc [ "kind", `String "git_push"; "remote", `String remote; "branch", `String branch; "force", `Bool force ]
  | Git_commit { message } ->
    `Assoc [ "kind", `String "git_commit"; "message", `String message ]
  | Gh_api_pr_create { repo; title; base } ->
    `Assoc [ "kind", `String "gh_api_pr_create"; "repo", `String repo; "title", `String title; "base", `String base ]
  | Gh_api_pr_merge { repo; pr_number } ->
    `Assoc [ "kind", `String "gh_api_pr_merge"; "repo", `String repo; "pr_number", `Int pr_number ]
  | Gh_api_pr_comment { repo; pr_number; body } ->
    `Assoc [ "kind", `String "gh_api_pr_comment"; "repo", `String repo; "pr_number", `Int pr_number; "body", `String body ]
  | Generic ->
    `Assoc [ "kind", `String "generic" ]

type ide_event =
  | Tool_event of tool_event
  | Turn_event of turn_event
  | Pr_event of pr_event

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

and pr_event =
  { pr_number : int
  ; pr_url : string
  ; pr_title : string
  ; pr_state : string
  ; repo : string
  ; keeper_id : string
  ; turn_id : string
  ; comment_count : int
  ; review_status : string option
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

let ide_event_to_json = function
  | Tool_event e -> tool_event_to_json e
  | Turn_event e -> turn_event_to_json e
  | Pr_event e -> pr_event_to_json e
