(** Infrastructure domain sub-store: Unified Sandboxes ([apple_container]
    microVMs + [remote_ssh] pools + Docker + host storage/GC), Repositories &
    Read-Only Diffs, and Unified Activity & System Logs bounded ring with typed
    [Stream_gap] accounting. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

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

type t = {
  active_tab : Nav.infra_tab;
  sandboxes : Wire_infra.sandboxes_snapshot Observed.t;
  sandboxes_fallback_404 : bool;
  keeper_sandbox : Wire_infra.keeper_sandbox_response Observed.t;
  repositories : Wire_infra.repository list Observed.t;
  repo_activity : repo_activity option;
  logs : Wire_infra.system_log_entry list;
  logs_loaded : bool;
  last_log_seq : int option;
  stream_gap_count : int;
  log_level_filter : Wire_infra.log_level option;
  log_keeper_filter : string option;
  activity_events : activity_row list;
  show_raw_json : bool;
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
val apply_keeper_sandbox :
  observed_at:Clock.Mono.t -> Wire_infra.keeper_sandbox_response -> t -> t
val apply_repositories :
  observed_at:Clock.Mono.t -> Wire_infra.repository list -> t -> t
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
(** Drop [last_log_seq], so the next log stream opens without a cursor and the
    server answers with a reset frame from its own ring. A new server process
    numbers its lines from zero again. *)
val apply_log_frame : Wire_infra.system_log_frame -> t -> t
(** A reset frame replaces the list and [last_log_seq]; any other frame
    appends its entries oldest first. *)
val push_activity : activity_row -> t -> t
val record_stream_gap : int -> t -> t

val visible_logs : t -> Wire_infra.system_log_entry list
val set_log_level_filter : Wire_infra.log_level option -> t -> t
val cycle_log_level_filter : t -> t
val set_log_keeper_filter : string option -> t -> t

val toggle_raw_json : t -> t

val filtered_sandbox_keepers : t -> string list
val filtered_repositories : t -> Wire_infra.repository list
val selected_sandbox_keeper : t -> string option
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
