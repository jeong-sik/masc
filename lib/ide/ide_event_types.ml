(** IDE Event Types — unified event model for Keeper activity visualization. *)

(** Structured descriptor for what a shell command did.
    Kept as an IDE-facing alias for the neutral [Command_descriptor.t]. *)
type command_descriptor = Command_descriptor.t =
  | Gh_pr_create of { title : string; base : string; draft : bool }
  | Gh_pr_search of { query : string; state : string option }
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
  | Pipe_chain of { first_cmd : string; last_cmd : string; length : int }
  | Generic

let command_descriptor_to_json = Command_descriptor.to_json

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
  ; command_descriptor : command_descriptor option
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
  ; pull_request_url : string
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
    ; "command_descriptor", (match e.command_descriptor with Some d -> command_descriptor_to_json d | None -> `Null)
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
    ; "pull_request_url", `String e.pull_request_url
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

(** Exit code semantics — many commands use exit codes to convey
    information beyond success/failure. Inspired by Claude Code's
    commandSemantics.ts. *)
type exit_semantics =
  | Success
  | No_matches
  | Files_differ
  | Condition_false
  | Error of string

let interpret_exit_code ~(cmd_name : string) ~(exit_code : int) : exit_semantics =
  match cmd_name, exit_code with
  (* grep/rg/ag/ack: 0=matches found, 1=no matches, 2+=error *)
  | ("grep" | "rg" | "ag" | "ack"), 0 -> Success
  | ("grep" | "rg" | "ag" | "ack"), 1 -> No_matches
  | ("grep" | "rg" | "ag" | "ack"), n -> Error (Printf.sprintf "exit %d" n)
  (* diff: 0=no differences, 1=differences found, 2+=error *)
  | "diff", 0 -> Success
  | "diff", 1 -> Files_differ
  | "diff", n -> Error (Printf.sprintf "exit %d" n)
  (* test/[: 0=condition true, 1=condition false, 2+=error *)
  | ("test" | "["), 0 -> Success
  | ("test" | "["), 1 -> Condition_false
  | ("test" | "["), n -> Error (Printf.sprintf "exit %d" n)
  (* find: 0=success, 1=partial success, 2+=error *)
  | "find", 0 -> Success
  | "find", 1 -> Success (* partial success is still success *)
  | "find", n -> Error (Printf.sprintf "exit %d" n)
  (* General: 0=success, anything else=error *)
  | _, 0 -> Success
  | _, n -> Error (Printf.sprintf "exit %d" n)

(** Classify a command into a broad category for UI display.
    Inspired by Claude Code's BASH_SEARCH/READ/LIST/SILENT_COMMANDS sets. *)
type cmd_category =
  | Search_cmd
  | Read_cmd
  | List_cmd
  | Silent_cmd
  | Neutral_cmd
  | Write_cmd

let classify_cmd_category ~(cmd_name : string) : cmd_category =
  match cmd_name with
  | "find" | "grep" | "rg" | "ag" | "ack" | "locate" | "which" | "whereis" -> Search_cmd
  | "cat" | "head" | "tail" | "less" | "more" | "wc" | "stat" | "file" | "strings"
  | "jq" | "awk" | "cut" | "sort" | "uniq" | "tr" -> Read_cmd
  | "ls" | "tree" | "du" -> List_cmd
  | "mv" | "cp" | "rm" | "mkdir" | "rmdir" | "chmod" | "chown" | "chgrp"
  | "touch" | "ln" | "cd" | "export" | "unset" | "wait" -> Silent_cmd
  | "echo" | "printf" | "true" | "false" | ":" -> Neutral_cmd
  | _ -> Write_cmd
