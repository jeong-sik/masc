(** Infrastructure domain sub-store: Unified Sandboxes ([apple_container]
    microVMs + [remote_ssh] pools + Docker + host storage/GC), Repositories &
    Read-Only Diffs, and Unified Activity & System Logs bounded ring with typed
    [Stream_gap] accounting. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_map : Map.S with type key = string

val max_logs : int
val max_activity : int

type activity_kind =
  | Activity_tool_call
  | Activity_turn_complete
  | Activity_agent_core
  | Activity_stream_gap

type activity_row = {
  at_unix : float;
  kind : activity_kind;
  keeper : string option;
  summary : string;
  detail : string option;
}

type repo_activity = {
  repo_id : string;  (** The repository this slot answers for. *)
  activity : Wire_infra.repository_activity Observed.t;
}

type activity_source_filter =
  | Source_all
  | Source_logs
  | Source_events

type timeline_entry =
  | Entry_log of Wire_infra.system_log_entry
  | Entry_event of activity_row
module String_set : Set.S with type elt = string

type code_right_mode =
  | Code_file
  | Code_search_results
  | Code_git_status
  | Code_git_branches
  | Code_git_worktrees
  | Code_git_blame
  | Code_git_log
  | Code_review

type code_state = {
  scope : Wire_infra.workspace_scope;
  expanded_dirs : String_set.t;
  children_by_dir : Wire_infra.workspace_tree_node list String_map.t;
  tree_loaded : bool;
  tree_selected_index : int;
  tree_scroll_offset : int;
  right_mode : code_right_mode;
  active_file_path : string option;
  open_file :
    (Wire_infra.workspace_scope * string * Wire_infra.workspace_file_content)
    Observed.t;
  file_scroll_offset : int;
  pending_jump_line : (string * int) option;
  files_catalog :
    (Wire_infra.workspace_scope * Wire_infra.workspace_files_catalog) Observed.t;
  search_result :
    (Wire_infra.workspace_scope * Wire_infra.workspace_search_result) Observed.t;
  search_selected_index : int;
  git_status :
    (Wire_infra.workspace_scope * Wire_infra.git_status_snapshot) Observed.t;
  git_branches :
    (Wire_infra.workspace_scope * Wire_infra.git_branch_entry list) Observed.t;
  git_worktrees :
    (Wire_infra.workspace_scope * Wire_infra.git_worktree_entry list) Observed.t;
  git_blame :
    (Wire_infra.workspace_scope * string * Wire_infra.git_blame_entry list)
    Observed.t;
  git_log :
    (Wire_infra.workspace_scope * string * Wire_infra.git_log_commit list)
    Observed.t;
  git_diff :
    (Wire_infra.workspace_scope * string * Wire_infra.git_diff_snapshot)
    Observed.t;
  git_scroll_offset : int;
}

type keeper_sandbox_read = {
  observation : Wire_infra.keeper_sandbox_response Observed.t;
  retained : (Wire_infra.keeper_sandbox_response * Clock.Mono.t) option;
  requested_at : Clock.Mono.t option;
  invalidated_during_read : bool;
}
(** The latest settlement, a retained detail after a failed refresh, and the
    dispatch time of the pending read. The invalidation flag carries a newer
    sandbox dataset notification across that read's settlement. *)

(** The File inspector's read. Loading and failure belong to this file, so
    one file's state never shows under another file's title. *)
type file_peek_read = {
  peek_keeper : string;
  peek_path : string;
  peek_content : Wire_infra.workspace_file_content Observed.t;
}

type t = {
  active_tab : Nav.infra_tab;
  sandboxes : Wire_infra.sandboxes_snapshot Observed.t;
  sandboxes_fallback_404 : bool;
  keeper_sandboxes : keeper_sandbox_read String_map.t;
      (** One slot per keeper the sandbox route was asked about. *)
  repositories : Wire_infra.repository list Observed.t;
  repository_pulls : Wire_infra.repository_pulls_snapshot Observed.t;
  repository_details : Wire_infra.repository_observation Observed.t String_map.t;
  repo_activity : repo_activity option;
  logs : Wire_infra.system_log_entry list;
  logs_loaded : bool;
  activity_events_loaded : bool;
  activity_seen_seqs : String_set.t;
  activity_seen_entries : (string * float) list;
  last_log_seq : int option;
  stream_gap_count : int;
  log_level_filter : Wire_infra.log_level option;
  log_keeper_filter : string option;
  source_filter : activity_source_filter;
  activity_events : activity_row list;
  acting_rail_open : bool;
  acting_selected_index : int;
  runtime_trace : (string * Wire_infra.runtime_trace_snapshot) Observed.t;
  code : code_state;
  file_peek : file_peek_read option;
      (** The File inspector's read. [None] until one opens. *)
  show_raw_json : bool;
  pending_sandbox_keeper : string option;
  selected_index : int;
  scroll_offset : int;
  diff_scroll_offset : int;
  change_selected_index : int;
  change_scroll_offset : int;
  detail_scroll_offset : int;
  filter_query : string;
}

val empty : t

val set_tab : Nav.infra_tab -> t -> t
val cycle_tab : Keymap.cycle_dir -> t -> t

val apply_sandboxes :
  observed_at:Clock.Mono.t -> Wire_infra.sandboxes_snapshot -> t -> t
val apply_sandboxes_fallback :
  observed_at:Clock.Mono.t ->
  wall_unix:float ->
  keepers:Wire_fleet.keeper_summary list ->
  sandbox_profiles:(string * Wire_fleet.keeper_sandbox_profile) list ->
  tool_series_totals:(int * int * float option) option ->
  t ->
  t
(** Synthesize a truthful fallback {!Wire_infra.sandboxes_snapshot} from
    keeper [meta.sandbox_profile] and 24h [tool_series] totals when
    [/api/v1/infra/sandboxes] returns HTTP 404 on older servers. *)
val keeper_sandbox_for :
  keeper:string -> t -> Wire_infra.keeper_sandbox_response Observed.t
(** [keeper]'s slot. [Unreported] until the route answers for [keeper]. *)

val keeper_sandbox_read_for : keeper:string -> t -> keeper_sandbox_read
val keeper_sandbox_detail :
  keeper_sandbox_read -> (Wire_infra.keeper_sandbox_response * Clock.Mono.t) option
val keeper_sandbox_notice_rows :
  has_displayed_rows:bool -> keeper_sandbox_read -> int
(** Rows reserved for the read status and optional source or error detail. *)

val set_keeper_sandbox :
  keeper:string ->
  ?retain_detail:bool -> Wire_infra.keeper_sandbox_response Observed.t -> t -> t

val request_keeper_sandbox : keeper:string -> now:Clock.Mono.t -> t -> t
val detach_keeper_sandbox_reads : t -> t
val clear_sandbox_observations : t -> t
(** Discard fleet and named reads after the workspace guard reports a mismatch. *)

val keeper_sandbox_needed : force:bool -> keeper:string -> t -> bool
val invalidate_sandboxes : ?keeper:string -> t -> t
(** A new sandbox dataset can replace a confirmed absence or a last value.
    A keeper scope limits named invalidation to that Keeper. A permanent read
    failure keeps its explicit retry requirement. *)
val apply_repositories :
  observed_at:Clock.Mono.t -> Wire_infra.repository list -> t -> t
val apply_repository_pulls :
  observed_at:Clock.Mono.t -> Wire_infra.repository_pulls_snapshot -> t -> t
val pulls_entry_for :
  repo_id:string -> t -> Wire_infra.repository_pulls_entry option
val apply_repository_detail :
  repo_id:string ->
  observed_at:Clock.Mono.t ->
  Wire_infra.repository_observation ->
  t ->
  t
val fail_repository_detail :
  repo_id:string ->
  (Wire_infra.repository_observation Observed.t ->
  Wire_infra.repository_observation Observed.t) ->
  t ->
  t
val repository_detail_for :
  repo_id:string -> t -> Wire_infra.repository_observation Observed.t
val request_repo_activity : repo_id:string -> t -> t
(** Point the changes panel at [repo_id]. A slot already for [repo_id] keeps
    what it holds; otherwise the panel waits for [repo_id]'s answer. *)

val apply_repo_activity :
  repo_id:string ->
  observed_at:Clock.Mono.t ->
  Wire_infra.repository_activity ->
  t ->
  t
(** Store the answer when [repo_id] is the selected repository. An answer for
    any other repository is stale and leaves [t] as it was. *)

val fail_repo_activity :
  repo_id:string ->
  (Wire_infra.repository_activity Observed.t ->
  Wire_infra.repository_activity Observed.t) ->
  t ->
  t
(** Apply a failed fetch to the slot when [repo_id] is the selected
    repository; a failure for any other repository is dropped. *)

val apply_log_snapshot : Wire_infra.system_log_entry list -> t -> t

val forget_log_cursor : t -> t
(** Drop [last_log_seq], reset log/activity backfill flags, and clear
    [activity_seen_seqs], so the next log stream and activity backfill start
    cleanly on a new server process whose sequence numbers restart from zero. *)
val apply_log_frame : Wire_infra.system_log_frame -> t -> t
(** A reset frame replaces the list and [last_log_seq]; any other frame
    appends its entries oldest first. *)
val push_activity : activity_row -> t -> t
val record_stream_gap : int -> t -> t

val visible_logs : t -> Wire_infra.system_log_entry list
val visible_activity_events : t -> activity_row list
val visible_timeline : t -> timeline_entry list
val set_source_filter : activity_source_filter -> t -> t
val cycle_source_filter : t -> t
val set_log_level_filter : Wire_infra.log_level option -> t -> t
val cycle_log_level_filter : t -> t
val set_log_keeper_filter : string option -> t -> t

val toggle_raw_json : t -> t

val filtered_sandbox_keepers : t -> string list
val filtered_repositories : t -> Wire_infra.repository list
val selected_sandbox_keeper : t -> string option
val select_sandbox_by_keeper : string -> t -> t
val selected_repository : t -> Wire_infra.repository option

val selected_repo_activity :
  t ->
  (Wire_infra.repository * Wire_infra.repository_activity Observed.t) option
(** {!selected_repository} with its activity, which is waiting while the slot
    holds another repository's answer. [None] when no repository is
    selected. *)

val repo_changes : t -> Wire_infra.file_change list
(** The selected repository's changes that match the filter, in server order;
    empty while its answer is not in. *)

val selected_change : t -> Wire_infra.file_change option

val change_preview_rows : Wire_infra.file_change -> Masc_tui_ui.Diff.numbered list
(** The rows the preview pane draws: the edit's before and after, the whole
    written body, or the inserted text, numbered where the row records the
    position. A materialized blob has no text to show. *)
val selected_log : t -> Wire_infra.system_log_entry option
val selected_timeline_entry : t -> timeline_entry option
val is_sandbox_related_log : Wire_infra.system_log_entry -> bool
(** [true] iff the log's source or module carries a sandbox/VM/SSH/container
    token (matched on identifier boundaries, not loose substrings). *)

val sandbox_inspector_logs : keeper:string -> t -> Wire_infra.system_log_entry list
(** Logs rendered in the sandbox inspector tail pane for [keeper]: keeper-scoped
    logs when present, else {!is_sandbox_related_log} entries. *)

val sandbox_inspector_event_count : keeper:string -> t -> int
(** Exact combined log + activity row count rendered in the sandbox inspector
    tail pane for [keeper]. *)

val move_selection :
  ?pane_index:int ->
  ?viewport_rows:int ->
  ?max_detail_scroll:int ->
  delta:int ->
  t ->
  t
val reset_detail_scroll : t -> t
val set_filter : string -> t -> t
val mark_stale_all : t -> t

val apply_activity_events_backfill : Wire_infra.activity_event_item list -> t -> t
val toggle_acting_rail : t -> t
val move_acting_selection : count:int -> delta:int -> t -> t
val apply_runtime_trace :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_infra.runtime_trace_snapshot ->
  t ->
  t
val runtime_trace_for :
  keeper:string -> t -> Wire_infra.runtime_trace_snapshot option

val equal_code_right_mode : code_right_mode -> code_right_mode -> bool
val code_right_mode_label : code_right_mode -> Say.t
val cycle_code_git_mode : t -> t
val set_code_right_mode : code_right_mode -> t -> t
val set_code_scope : Wire_infra.workspace_scope -> t -> t
val visible_code_tree_nodes : t -> Wire_infra.workspace_tree_node list
val selected_code_tree_node : t -> Wire_infra.workspace_tree_node option
val toggle_code_dir : string -> t -> t
val apply_workspace_children :
  scope:Wire_infra.workspace_scope ->
  dir:string ->
  Wire_infra.workspace_tree_node list ->
  t ->
  t
val apply_workspace_files :
  observed_at:Clock.Mono.t ->
  scope:Wire_infra.workspace_scope ->
  Wire_infra.workspace_files_catalog ->
  t ->
  t
val apply_workspace_search :
  observed_at:Clock.Mono.t ->
  scope:Wire_infra.workspace_scope ->
  Wire_infra.workspace_search_result ->
  t ->
  t
val apply_workspace_file :
  observed_at:Clock.Mono.t ->
  scope:Wire_infra.workspace_scope ->
  path:string ->
  Wire_infra.workspace_file_content ->
  t ->
  t
val set_code_active_file : string option -> t -> t
val active_code_file_path : t -> string option
val open_file_for_current : t -> Wire_infra.workspace_file_content option
val review_changes : t -> Wire_infra.git_status_change list
(** Changed files of the current scope's git status, in server order. *)

val review_selected_index : t -> int option
(** Position of the active file in [review_changes]. *)

val select_review_change : delta:int -> t -> t
(** Move the review selection [delta] changes (clamped) and make that change
    the active file. With no selection, [delta >= 0] picks the first change and
    a negative [delta] the last. *)

val review_diff_rows : cols:int -> t -> Code_review_layout.row list
(** The selected change's diff as Review rows for a [cols]-wide viewport.
    Empty until that change's diff has arrived. *)

val code_review_active : t -> bool
(** The Code tab shows Review. *)

val step_review_hunk : cols:int -> delta:int -> t -> t
(** Scroll the Review diff to the next ([delta > 0]) or previous hunk header.
    Unchanged when there is none that way. *)

val open_file_peek : keeper:string -> path:string -> t -> t
(** Start a fresh read for this Keeper and path. Every open reads again, so a
    file the Keeper changed since the last open is not shown stale. *)

val file_peek_state :
  keeper:string -> path:string -> t -> Wire_infra.workspace_file_content Observed.t
(** The read for this Keeper and path, or [Unreported] when the slot holds
    another file or none. *)

val file_peek_content :
  keeper:string -> path:string -> t -> Wire_infra.workspace_file_content option
(** The File inspector's content when it is for this Keeper and path. *)

val apply_file_peek :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  path:string ->
  Wire_infra.workspace_file_content ->
  t ->
  t

val fail_file_peek :
  keeper:string ->
  path:string ->
  failure:
    (Wire_infra.workspace_file_content Observed.t ->
    Wire_infra.workspace_file_content Observed.t) ->
  t ->
  t
(** [apply_file_peek] and [fail_file_peek] change the slot only when it holds
    this Keeper and path; a late reply for another file is dropped. *)

val apply_git_status :
  observed_at:Clock.Mono.t ->
  scope:Wire_infra.workspace_scope ->
  Wire_infra.git_status_snapshot ->
  t ->
  t
val apply_git_branches :
  observed_at:Clock.Mono.t ->
  scope:Wire_infra.workspace_scope ->
  Wire_infra.git_branch_entry list ->
  t ->
  t
val apply_git_worktrees :
  observed_at:Clock.Mono.t ->
  scope:Wire_infra.workspace_scope ->
  Wire_infra.git_worktree_entry list ->
  t ->
  t
val apply_git_blame :
  observed_at:Clock.Mono.t ->
  scope:Wire_infra.workspace_scope ->
  path:string ->
  Wire_infra.git_blame_entry list ->
  t ->
  t
val apply_git_log :
  observed_at:Clock.Mono.t ->
  scope:Wire_infra.workspace_scope ->
  path:string ->
  Wire_infra.git_log_commit list ->
  t ->
  t
val git_diff_target_matches :
  scope:Wire_infra.workspace_scope -> path:string -> t -> bool
(** [true] when a diff reply for [scope] and [path] belongs to the file the
    Code tab shows now. A reply for any other file is late and is dropped. *)

val apply_git_diff :
  observed_at:Clock.Mono.t ->
  scope:Wire_infra.workspace_scope ->
  path:string ->
  Wire_infra.git_diff_snapshot ->
  t ->
  t
val find_log_by_seq : int -> t -> Wire_infra.system_log_entry option
