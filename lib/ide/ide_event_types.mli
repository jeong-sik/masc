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

val command_descriptor_to_json : command_descriptor -> Yojson.Safe.t

(** Exit code semantics — many commands use exit codes to convey
    information beyond success/failure. *)
type exit_semantics =
  | Success
  | No_matches
  | Files_differ
  | Condition_false
  | Error of string

val interpret_exit_code : cmd_name:string -> exit_code:int -> exit_semantics

(** Classify a command into a broad category for UI display. *)
type cmd_category =
  | Search_cmd
  | Read_cmd
  | List_cmd
  | Silent_cmd
  | Neutral_cmd
  | Write_cmd

val classify_cmd_category : cmd_name:string -> cmd_category

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

val ide_event_to_json : ide_event -> Yojson.Safe.t
