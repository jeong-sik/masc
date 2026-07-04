(** Neutral runtime observation bus for agent activity.

    Producers in Keeper/Tooling emit here without depending on any UI/IDE
    storage module. Consumers register process-local sinks that translate
    these neutral records into their own persistence or streaming surfaces. *)

type tool_event =
  { base_path : string
  ; tool_name : string
  ; keeper_id : string
  ; turn_id : string
  ; outcome : string
  ; typed_outcome : string
  ; duration_ms : float
  ; output_text : string
  ; input : Yojson.Safe.t
  }

type pr_event =
  { base_path : string
  ; keeper_id : string
  ; turn_id : string
  ; output_text : string
  ; tool_name : string
  ; success : bool
  }

type turn_event =
  { base_path : string
  ; turn_id : string
  ; keeper_id : string
  ; phase : string
  ; model_used : string option
  ; tools_used : string list
  ; stop_reason : string option
  ; duration_ms : int option
  ; timestamp_ms : int64
  }

type codebase_partition =
  | By_url of string
      (** canonical URL 정상 resolved: host_path slug. *)
  | No_canonical_url
      (** [canonical_url_of_remote] returned None: blank [repo.url] or malformed
          remote. v2 §7 "(1) 빈 repo/remote 없음". *)
  | Unmatched
      (** Caller passed [repo_id] but the repository store could not resolve it.
          v2 §7 "(2) repo_id unmatched". *)
  | Base_unresolved
      (** [file_path] under no registered repo (unregistered worktree, outside
          playground). v2 §7 "(4) base 경로 소실" — write-path [unregistered_repo]
          is the live instance. *)
  | Legacy_default
      (** No [canonical_url]/[repo_id] supplied, or record has no [partition]
          field (tool/turn/pr_event). Structural ceiling, NOT a soft fallback.
          v2 §7 "(3) default 미갱신". *)

val canonical_url_of_remote : string -> string option
(** [canonical_url_of_remote remote] normalises a git remote string into a
    deterministic host_path slug. Returns [None] for blank, malformed, or
    traversal-looking inputs. *)

type write_region_event =
  { base_path : string
  ; partition : codebase_partition
  ; keeper_id : string
  ; turn : int
  ; tool_call_json : Yojson.Safe.t
  }

type annotation_kind =
  | Comment
  | Decision
  | Question
  | Bookmark

val annotation_kind_to_string : annotation_kind -> string
val annotation_kind_of_string : string -> annotation_kind option

type annotation_request =
  { base_path : string
  ; keeper_id : string
  ; file_path : string
  ; line_start : int
  ; line_end : int
  ; kind : annotation_kind
  ; content : string
  ; goal_id : string option
  ; task_id : string option
  ; board_post_id : string option
  ; comment_id : string option
  ; pr_id : string option
  ; git_ref : string option
  ; log_id : string option
  ; session_id : string option
  ; operation_id : string option
  ; worker_run_id : string option
  }

type annotation_result =
  { id : string
  ; file_path : string
  ; line_start : int
  ; line_end : int
  }

type tool_event_sink = tool_event -> unit
type pr_event_sink = pr_event -> unit
type turn_event_sink = turn_event -> unit
type write_region_sink = write_region_event -> unit
type annotation_sink = annotation_request -> (annotation_result, string) result

val register_tool_event_sink : tool_event_sink -> unit
val register_pr_event_sink : pr_event_sink -> unit
val register_turn_event_sink : turn_event_sink -> unit
val register_write_region_sink : write_region_sink -> unit
val register_annotation_sink : annotation_sink -> unit

val emit_tool_event : tool_event -> unit
val emit_pr_event : pr_event -> unit
val emit_turn_event : turn_event -> unit
val emit_write_region_event : write_region_event -> unit
val emit_annotation_request : annotation_request -> (annotation_result, string) result

val reset_for_testing : unit -> unit
(** Reset sinks to no-op. Intended for isolated tests only. *)
