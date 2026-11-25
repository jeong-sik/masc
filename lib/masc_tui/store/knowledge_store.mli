(** Knowledge domain sub-store: Signal-first Board ([signal_only = true] by
    default), succession chain expand set, Wiki index/page/log/search/lint
    + the edit form's base page, Artifacts, World Memory conflicts +
    Librarian writer recovery acts, and Temporal Memory Diff
    ([24h | 7d | 30d | revs]). *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_set : Set.S with type elt = string
module String_map : Map.S with type key = string

type memory_diff_window =
  | Window_24h
  | Window_7d
  | Window_30d
  | Window_revs of { from_rev : int; to_rev : int }

module Memory_diff_map :
  Map.S with type key = string option * memory_diff_window
(** Memory diffs by what the request asked for: the keeper ([None] for world
    memory) and the window. *)

type memory_view_mode =
  | View_evolution
  | View_facts
  | View_diff

type memory_facts_sort =
  | Sort_recency
  | Sort_retrieved

type memory_left_row =
  | Left_conflict of Wire_knowledge.memory_conflict
  | Left_world_scope
  | Left_writer of Wire_knowledge.librarian_writer_row

type memory_fact_row =
  | Fact_ordinary of {
      revision : int;
      fact : Wire_knowledge.keeper_ordinary_fact;
    }
  | Fact_source of Wire_knowledge.keeper_source_fact
  | Fact_source_invalidation of Wire_knowledge.keeper_source_invalidation

type memory_diff_item =
  | Keeper_added of Wire_knowledge.memory_fact_entry
  | Keeper_updated of Wire_knowledge.memory_updated_fact
  | Keeper_retracted of Wire_knowledge.memory_retracted_fact
  | Keeper_invalidated of Wire_knowledge.memory_invalidated_fact
  | World_added of Wire_knowledge.world_change_entry
  | World_updated of Wire_knowledge.world_updated_entry
  | World_retracted of Wire_knowledge.world_change_entry

type memory_reading_entry =
  | Reading_activity of {
      keeper : string;
      event : Wire_knowledge.memory_activity_event;
      notes : string list;
    }
  | Reading_ordinary_fact of {
      keeper : string;
      revision : int;
      fact : Wire_knowledge.keeper_ordinary_fact;
    }
  | Reading_source_fact of {
      keeper : string;
      fact : Wire_knowledge.keeper_source_fact;
    }
  | Reading_source_invalidation of {
      keeper : string;
      invalidation : Wire_knowledge.keeper_source_invalidation;
    }
  | Reading_diff_item of {
      keeper : string option;
      item : memory_diff_item;
    }

type memory_diagram_kind =
  | Diagram_pele_card
  | Diagram_formation_tree

type memory_diagram_mode =
  | Diagram_mode_auto
  | Diagram_mode_mermaid
  | Diagram_mode_tree

type memory_diagram_payload =
  | Diagram_pele_png of {
      png : string;
      pixel_size : (int * int) option;
      format_label : string;
      fallback_lines : string list;
    }
  | Diagram_text of {
      lines : string list;
      note : string option;
    }

type memory_diagram_source =
  | Diagram_source_event of string
  | Diagram_source_fact_snapshot of string

type memory_diagram_state = {
  request_id : int;
  keeper : string;
  event_identity : string;
  source : memory_diagram_source;
  revision : int;
  kind : memory_diagram_kind;
  mode : memory_diagram_mode;
  payload : memory_diagram_payload Observed.t;
  scroll : int;
  copy_source : string;
}

(** The page an open wiki edit form started from. The form's text came from
    this revision, so its save names this revision and sha256, and the
    server refuses the save if the page changed since. *)
type wiki_edit_base = {
  slug : string;
  revision : int;
  sha256 : string;
  source : Wire_knowledge.wiki_source;
  tags : string list;
}

type vote_target =
  | Vote_post of string
  | Vote_comment of { post_id : string; comment_id : string }

type threaded_comment = {
  comment : Wire_knowledge.board_comment;
  depth : int;
  is_reply : bool;
}

type thread_view = Thread_post | Thread_comments

type memory_subview =
  | Mem_diff_flow
  | Mem_health_ledger
  | Mem_context

type keeper_memory_subview =
  | Kmem_diff_flow
  | Kmem_health
  | Kmem_facts_tree
  | Kmem_journal

type t = {
  active_tab : Nav.knowledge_tab;
  board_recovery : Board_recovery.t;
  board : Wire_knowledge.board_feed Observed.t;
  board_feed_meta : Wire_knowledge.board_feed_meta option;
  board_thread_meta : Wire_knowledge.board_thread_meta option;
  board_hearths : Wire_knowledge.board_hearth_entry list Observed.t;
  board_signal_only : bool;
  board_sort_by : string;
  board_hearth : string option;
  expanded_succession_chains : String_set.t;
  active_thread :
    (Wire_knowledge.board_post * Wire_knowledge.board_comment list) Observed.t;
  active_thread_target : string option;
  thread_view : thread_view;
  thread_selected_comment : string option;
  thread_comment_scroll : int;
  armed_vote : (vote_target * [ `Up | `Down ]) option;
  wiki_index : Wire_knowledge.wiki_index Observed.t;
  wiki_pages : Wire_knowledge.wiki_page_detail Observed.t String_map.t;
      (** One slot per page slug. *)
  wiki_log : Wire_knowledge.wiki_log_response Observed.t;
  wiki_search : Wire_knowledge.wiki_search_response Observed.t;
  wiki_lint : Wire_knowledge.wiki_lint_report Observed.t;
  wiki_edit_base : wiki_edit_base option;
  pending_wiki_edit_slug : string option;
      (** Wiki slug whose edit modal should open automatically once its fresh
          page detail arrives (Issue #54490). *)
  artifacts : Wire_knowledge.artifact_entry list Observed.t;
  active_artifact_detail : Wire_knowledge.published_artifact_detail Observed.t;
  active_artifact_detail_target : string option;
  pending_artifact_revision : (string * int option) option;
  artifact_view_mode : [ `Document | `Raw_source ];
  artifact_checks : Wire_knowledge.artifact_check list Observed.t;
  artifact_search_query : string;
  artifact_search_match_idx : int;
  world_memory : Wire_knowledge.world_memory Observed.t;
  memory_diffs : Wire_knowledge.memory_diff Observed.t Memory_diff_map.t;
  memory_os_internals :
    Wire_knowledge.memory_os_internals Observed.t String_map.t;
      (** One slot per keeper. *)
  keeper_memory_facts :
    Wire_knowledge.keeper_memory_facts Observed.t String_map.t;
      (** One slot per keeper. *)
  keeper_memory_activity :
    Wire_knowledge.keeper_memory_activity Observed.t String_map.t;
      (** One slot per keeper. *)
  keeper_memory_health : Wire_knowledge.keeper_memory_health_fleet Observed.t;
  memory_subview : memory_subview;
  keeper_memory_subview : keeper_memory_subview;
  memory_health_keeper :
    (string * Wire_knowledge.keeper_memory_health_row option) Observed.t;
  workspace_memory_ledger : Wire_knowledge.workspace_memory_ledger Observed.t;
  workspace_memory_ledger_auth_denied : bool;
  workspace_memory_context : Wire_knowledge.workspace_memory_context Observed.t;
  workspace_memory_context_auth_denied : bool;
  keeper_memory_facts_auth_denied : String_set.t;
  collapsed_fact_categories : String_set.t;
  facts_selected_index : int;
  keeper_memory_journal :
    (string * Wire_knowledge.keeper_memory_journal) Observed.t;
  keeper_memory_journal_auth_denied : String_set.t;
  memory_subview_scroll : int;
  memory_diff_window : memory_diff_window;
  memory_diff_keeper : string option;
  memory_view_mode : memory_view_mode;
  memory_facts_sort : memory_facts_sort;
  selected_fact_index : int;
  facts_scroll_offset : int;
  selected_activity_index : int;
  activity_scroll_offset : int;
  selected_diff_index : int;
  memory_reading : memory_reading_entry option;
  memory_reading_scroll : int;
  memory_diagram : memory_diagram_state option;
  memory_diagram_seq : int;
  memory_flow_mode : Masc_tui_ui.Memory_flow.chart_mode;
  last_memory_act_answer : (string * Wire_knowledge.memory_act_answer) option;
  selected_index : int;
  scroll_offset : int;
  diff_scroll_offset : int;
  detail_scroll_offset : int;
  pulse_thread_index : int;
  filter_query : string;
}

val empty : t

val wiki_page_for :
  slug:string -> t -> Wire_knowledge.wiki_page_detail Observed.t
(** [slug]'s slot. [Unreported] until the page route answers for [slug]. *)
val set_wiki_page :
  slug:string -> Wire_knowledge.wiki_page_detail Observed.t -> t -> t

val memory_diff_for :
  keeper:string option ->
  window:memory_diff_window ->
  t ->
  Wire_knowledge.memory_diff Observed.t
(** The diff of [keeper]'s memory ([None]: world memory) over [window].
    [Unreported] until the diff route answers for that pair. *)
val set_memory_diff :
  keeper:string option ->
  window:memory_diff_window ->
  Wire_knowledge.memory_diff Observed.t ->
  t ->
  t
val current_memory_diff : t -> Wire_knowledge.memory_diff Observed.t
(** The Knowledge Memory tab's diff: [memory_diff_keeper] over
    [memory_diff_window]. *)

val memory_os_internals_for :
  keeper:string -> t -> Wire_knowledge.memory_os_internals Observed.t
(** [keeper]'s slot. [Unreported] until the internals route answers for
    [keeper]. *)
val set_memory_os_internals :
  keeper:string -> Wire_knowledge.memory_os_internals Observed.t -> t -> t

val keeper_memory_facts_for :
  keeper:string -> t -> Wire_knowledge.keeper_memory_facts Observed.t
(** [keeper]'s slot. [Unreported] until the facts route answers for
    [keeper]. *)
val set_keeper_memory_facts :
  keeper:string -> Wire_knowledge.keeper_memory_facts Observed.t -> t -> t

val keeper_memory_activity_for :
  keeper:string -> t -> Wire_knowledge.keeper_memory_activity Observed.t
(** [keeper]'s slot. [Unreported] until the activity route answers for
    [keeper]. *)
val set_keeper_memory_activity :
  keeper:string -> Wire_knowledge.keeper_memory_activity Observed.t -> t -> t

val memory_diff_window_query : memory_diff_window -> string option
val equal_memory_diff_window : memory_diff_window -> memory_diff_window -> bool
val equal_memory_view_mode : memory_view_mode -> memory_view_mode -> bool
val equal_memory_facts_sort : memory_facts_sort -> memory_facts_sort -> bool
val equal_memory_diagram_kind :
  memory_diagram_kind -> memory_diagram_kind -> bool
val equal_memory_diagram_mode :
  memory_diagram_mode -> memory_diagram_mode -> bool
val next_memory_diagram_mode : memory_diagram_mode -> memory_diagram_mode
val equal_vote_target : vote_target -> vote_target -> bool

val set_tab : Nav.knowledge_tab -> t -> t
val cycle_tab : Keymap.cycle_dir -> t -> t

val toggle_signal_only : t -> t
val set_board_sort : string -> t -> t
val cycle_board_sort : t -> t
val set_board_hearth : string option -> t -> t
val cycle_board_hearth : t -> t
val toggle_succession_chain : root_id:string -> t -> t
val is_succession_chain_expanded : root_id:string -> t -> bool

val order_comments_threaded :
  Wire_knowledge.board_comment list -> threaded_comment list
(** Thread comments by [parent_id] up to depth 4, chronologically per parent,
    promoting orphans and breaking cycles safely. *)

val reset_thread_view : t -> t
val toggle_thread_view : t -> t
val restore_thread_comment : post_id:string -> previous:t -> t -> t
(** Keep the same comment and scroll position when a thread refresh returns it. *)

val thread_reading_rect : bp:Masc_tui_ui.Layout.breakpoint -> t -> Rect.t -> Rect.t
(** Markdown area inside a thread with its tab bar, border, and metadata. *)

val step_thread_comment : post_id:string -> delta:int -> t -> t
(** Open the comment reader and advance within the loaded [post_id] thread. *)

val selected_thread_comment : post_id:string -> t -> threaded_comment option
(** The comment displayed in the comment reader for the matching post. *)

val selected_thread_comment_at : post_id:string -> t -> (int * threaded_comment) option
(** The selected comment and its zero-based position in thread order. *)

val press_vote :
  target:vote_target ->
  dir:[ `Up | `Down ] ->
  t ->
  [ `Armed of t | `Confirmed of t ]
(** Two-press armed vote state machine: first press arms [(target, dir)],
    matching second press confirms and clears. *)

val clear_armed_vote : t -> t

val toggle_artifact_view_mode : t -> t
val apply_artifact_checks :
  observed_at:Clock.Mono.t -> Wire_knowledge.artifact_check list -> t -> t
val apply_artifact_check_update :
  observed_at:Clock.Mono.t -> Wire_knowledge.artifact_check -> t -> t
val artifact_check_for :
  id:string -> ?revision:int -> t -> Wire_knowledge.artifact_check option
val set_pending_artifact_revision :
  (string * int option) option -> t -> t
val clear_pending_artifact_revision : t -> t
val is_json_artifact : Wire_knowledge.artifact_entry -> bool
val matches_pending_artifact_revision :
  id:string -> revision:int -> t -> bool
val apply_artifact_share_result :
  observed_at:Clock.Mono.t -> Wire_knowledge.artifact_share_result -> t -> t
val set_artifact_search : string -> t -> t
val step_artifact_search_match : delta:int -> match_count:int -> t -> t
val artifact_revision_step : delta:int -> t -> (string * int) option

val set_memory_diff_window : memory_diff_window -> t -> t
val cycle_memory_diff_window : t -> t
val set_memory_diff_keeper : string option -> t -> t
val set_memory_view_mode : memory_view_mode -> t -> t
val cycle_memory_view_mode : t -> t
val set_memory_facts_sort : memory_facts_sort -> t -> t
val toggle_memory_facts_sort : t -> t
val open_memory_reading : memory_reading_entry -> t -> t
val close_memory_reading : t -> t
val memory_reading_matches_scope :
  keeper_opt:string option -> memory_reading_entry -> bool
val scroll_memory_reading : max_scroll:int -> delta:int -> t -> t

val next_memory_diagram_request_id : t -> int
(** Next strictly monotonic request nonce for opening/refreshing a memory
    diagram. Never resets on diagram close or scope change. *)

val open_memory_diagram : memory_diagram_state -> t -> t
val close_memory_diagram : t -> t
val memory_diagram_matches_scope :
  keeper_opt:string option -> memory_diagram_state -> bool
val scroll_memory_diagram : max_scroll:int -> delta:int -> t -> t
val apply_memory_diagram_result :
  observed_at:Clock.Mono.t ->
  request_id:int ->
  keeper:string ->
  event_identity:string ->
  kind:memory_diagram_kind ->
  mode:memory_diagram_mode ->
  (memory_diagram_payload, string) result ->
  t ->
  t

type reading_line_tone =
  | Reading_anchor
  | Reading_primary
  | Reading_structure of { bold : bool }
  | Reading_whisper of { italic : bool }
  | Reading_status of { tone : Theme.status_token; bold : bool }

type reading_line_content =
  | Reading_plain of reading_line_tone * string
  | Reading_markdown of Masc_tui_ui.Markdown.rendered_line

type reading_line = {
  rail : Theme.status_token option;
  content : reading_line_content;
}

val wrap_lines : max_width:int -> string -> string list
(** Word-aware, grapheme-safe UTF-8/CJK multi-line text wrapping. *)

val project_memory_reading_lines :
  theme:Theme.t ->
  width:int ->
  lang:Say.lang ->
  now_unix:float ->
  memory_reading_entry ->
  reading_line list
(** Single-SSOT wrapped full-reading line layout shared by {!Update_nav}
    scroll bounds and [Memory_explorer.render_full_reading]. *)
val move_memory_activity :
  keeper:string -> ?viewport_rows:int -> delta:int -> t -> t
val move_memory_facts :
  keeper:string -> ?viewport_rows:int -> delta:int -> t -> t
val move_memory_diff_cursor : delta:int -> t -> t
val toggle_memory_flow_mode : t -> t

val scope_memory_diff_dive :
  keeper:string option -> from_rev:int -> to_rev:int -> t -> t
(** [t] reading [keeper]'s diff over [Window_revs { from_rev; to_rev }], the
    slot a [Memory_diff_dive] fetches into. The result's [memory_diff_keeper]
    and [memory_diff_window] belong to the dive, not to the Memory tab: keep
    the original [t] as the model's knowledge. *)

val move_memory_diff_dive_cursor :
  keeper:string option ->
  from_rev:int ->
  to_rev:int ->
  delta:int ->
  t ->
  t
(** {!move_memory_diff_cursor} over the dive's own diff. Only
    [selected_diff_index] of [t] changes; the Memory tab's window and keeper
    stay as they were. *)

val apply_board :
  observed_at:Clock.Mono.t -> Wire_knowledge.board_feed -> t -> t
val apply_board_hearths :
  observed_at:Clock.Mono.t -> Wire_knowledge.board_hearth_entry list -> t -> t
val apply_thread :
  observed_at:Clock.Mono.t ->
  Wire_knowledge.board_post * Wire_knowledge.board_comment list ->
  t ->
  t
val mark_thread_loading :
  ?force:bool -> post_id:string -> since_ns:Clock.Mono.t -> t -> t
(** Mark [active_thread] as [Observed.Loading] for [post_id] and clear stale
    comment selection / armed vote. Unless [force = true], preserves an
    already-loaded [Value], already-[Loading] slot, or settled non-retryable
    [Failed] state for the same [post_id]. *)
val mark_thread_failed :
  ?target:string ->
  at:Clock.Mono.t ->
  reason:string ->
  retryable:bool ->
  t ->
  t
val apply_wiki_index :
  observed_at:Clock.Mono.t -> Wire_knowledge.wiki_index -> t -> t
val apply_wiki_log :
  observed_at:Clock.Mono.t -> Wire_knowledge.wiki_log_response -> t -> t
val apply_wiki_search :
  observed_at:Clock.Mono.t -> Wire_knowledge.wiki_search_response -> t -> t
val apply_wiki_lint :
  observed_at:Clock.Mono.t -> Wire_knowledge.wiki_lint_report -> t -> t
val apply_artifacts :
  observed_at:Clock.Mono.t -> Wire_knowledge.artifact_entry list -> t -> t
val apply_artifact_detail :
  observed_at:Clock.Mono.t ->
  Wire_knowledge.published_artifact_detail ->
  t ->
  t
val mark_artifact_detail_failed :
  ?target:string ->
  at:Clock.Mono.t ->
  reason:string ->
  retryable:bool ->
  t ->
  t
val apply_world_memory :
  observed_at:Clock.Mono.t -> Wire_knowledge.world_memory -> t -> t
val apply_keeper_memory_facts :
  observed_at:Clock.Mono.t ->
  ?keeper:string ->
  Wire_knowledge.keeper_memory_facts ->
  t ->
  t
val apply_keeper_memory_health :
  observed_at:Clock.Mono.t -> Wire_knowledge.keeper_memory_health_fleet -> t -> t
val fail_keeper_memory_health :
  reason:string -> retryable:bool -> at:Clock.Mono.t -> t -> t
val record_memory_act_answer :
  keeper:string -> Wire_knowledge.memory_act_answer -> t -> t

val request_wiki_edit : slug:string -> t -> t
(** Remember that the operator pressed [e] on [slug] while its page body was
    missing or stale, so the edit modal opens when the fresh page arrives. *)

val clear_pending_wiki_edit : t -> t
(** Forget any pending auto-open wiki edit request. *)

val begin_wiki_edit : Wire_knowledge.wiki_page_detail -> t -> t
(** Remember [page] as the base of the edit form that opens on it. *)

val end_wiki_edit : t -> t
(** Forget the base once the form is submitted. *)

type succession_group = {
  chain_root_id : string option;
  lead : Wire_knowledge.board_post;
  members : Wire_knowledge.board_post list;
  chain_count : int;
  unique_keepers : int;
}

val filtered_posts : t -> Wire_knowledge.board_post list
val group_succession_chains :
  Wire_knowledge.board_post list -> succession_group list
(** Canonical SSOT succession-chain grouping for Board posts. *)

val board_display_posts : t -> Wire_knowledge.board_post list
(** Visual display order of selectable Board posts: collapsed/singleton chains
    yield [[grp.lead]], expanded multi-member chains yield [grp.members]. *)

val wiki_pages_filtered : t -> Wire_knowledge.wiki_page_summary list
val cluster_wiki_pages :
  Wire_knowledge.wiki_page_summary list ->
  (string option * Wire_knowledge.wiki_page_summary list) list
(** Language-neutral topic clustering of Wiki pages ([None] represents
    untagged General pages). *)

val wiki_display_pages : t -> Wire_knowledge.wiki_page_summary list
(** Flattened visual display order matching {!cluster_wiki_pages}. *)

val filtered_memory_conflicts : t -> Wire_knowledge.memory_conflict list
val filtered_memory_claims : t -> Wire_knowledge.world_claim list
val filtered_librarian_writers : t -> Wire_knowledge.librarian_writer_row list
val memory_left_rows : t -> memory_left_row list
val selected_memory_left_row : t -> memory_left_row option
val memory_change_time : rev:int option -> at:float option -> string

val memory_diff_matches_filter : t -> string -> bool

val health_row_for_keeper :
  keeper:string -> t -> Wire_knowledge.keeper_memory_health_row option

val filtered_memory_activity_events :
  keeper:string -> t -> Wire_knowledge.memory_activity_event list

val selected_activity_event_for :
  keeper:string -> t -> Wire_knowledge.memory_activity_event option

val selected_activity_event : t -> Wire_knowledge.memory_activity_event option
(** Selected memory activity event in the current memory explorer scope.
    Clean hook for PR 2 Pele Card ([.]) and Formation Tree ([Ctrl+O]). *)

val filtered_memory_fact_rows :
  keeper:string -> t -> memory_fact_row list

val selected_memory_fact_row :
  keeper:string -> t -> memory_fact_row option

val filtered_memory_diff_items_for :
  keeper_opt:string option -> t -> memory_diff_item list
(** Filtered items of [keeper_opt]'s diff over [memory_diff_window]
    ([None]: world memory). *)

val filtered_memory_diff_items : t -> memory_diff_item list
(** Single-SSOT filtered diff items for [t.memory_diff_keeper]. *)

val selected_memory_diff_item_for :
  keeper_opt:string option -> t -> memory_diff_item option

val selected_memory_diff_item : t -> memory_diff_item option

val memory_diff_entry_count : t -> int
val memory_diff_line_count : t -> int
(** Exact flattened visual line count of {!filtered_memory_diff_items} for
    line-level scrolling in [3 Knowledge > Memory] and [Memory_diff_dive]. *)

val keeper_memory_diff_line_count : name:string -> t -> int
(** Exact rendered line count of [name]'s diff over [memory_diff_window] in
    the [Keeper_memory] tab. *)

val hottest_signal_threads : t -> Wire_knowledge.board_post list
val selected_pulse_thread : t -> Wire_knowledge.board_post option
val move_pulse_thread : ?viewport_rows:int -> delta:int -> t -> t
val selected_post : t -> Wire_knowledge.board_post option

(** What [Space] does on the Board list: it folds the selected post's
    succession chain when the post belongs to one, and otherwise flips the
    Signal-only / All filter. The key handler and the card hint both read this,
    so the hint names the action the key runs. *)
type board_space_effect =
  | Board_space_toggle_chain of string
  | Board_space_toggle_signal_only

val selected_post_expandable_chain_root : t -> string option
val board_space_effect : t -> board_space_effect

val selected_wiki_page : t -> Wire_knowledge.wiki_page_summary option

val artifacts_filtered : t -> Wire_knowledge.artifact_entry list
(** The Artifacts list rows: every artifact whose title, id or body SHA-256
    contains the filter text. *)

val selected_artifact : t -> Wire_knowledge.artifact_entry option
val find_artifact_by_id_or_sha :
  string -> t -> Wire_knowledge.artifact_entry option
val artifact_detail_for_entry :
  Wire_knowledge.artifact_entry ->
  t ->
  Wire_knowledge.published_artifact_detail option
val artifact_detail_failure_for_entry :
  Wire_knowledge.artifact_entry -> t -> string option
val artifact_preview_lines :
  Wire_knowledge.artifact_entry ->
  Wire_knowledge.published_artifact_detail option ->
  string list
val memory_flow_input_of_diff :
  Wire_knowledge.memory_diff ->
  memory_diff_window ->
  Masc_tui_ui.Memory_flow.input

val artifact_by_id : t -> string -> Wire_knowledge.artifact_entry option
(** The loaded artifact an [Artifact_dive] names. *)

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

val equal_memory_subview : memory_subview -> memory_subview -> bool
val cycle_memory_subview : t -> t
val set_memory_subview : memory_subview -> t -> t
val equal_keeper_memory_subview :
  keeper_memory_subview -> keeper_memory_subview -> bool
val cycle_keeper_memory_subview : t -> t
val set_keeper_memory_subview : keeper_memory_subview -> t -> t
val apply_memory_health_fleet :
  observed_at:Clock.Mono.t ->
  Wire_knowledge.keeper_memory_health_fleet ->
  t ->
  t
val apply_memory_health_keeper :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_knowledge.keeper_memory_health_row option ->
  t ->
  t
val mark_memory_health_keeper_failed :
  at:Clock.Mono.t ->
  ?active_keeper:string ->
  keeper:string ->
  reason:string ->
  retryable:bool ->
  t ->
  t
val apply_workspace_memory_ledger :
  observed_at:Clock.Mono.t -> Wire_knowledge.workspace_memory_ledger -> t -> t
val mark_workspace_memory_ledger_failed :
  at:Clock.Mono.t -> reason:string -> retryable:bool -> auth_denied:bool -> t -> t
val apply_workspace_memory_context :
  observed_at:Clock.Mono.t -> Wire_knowledge.workspace_memory_context -> t -> t
val mark_workspace_memory_context_failed :
  at:Clock.Mono.t -> reason:string -> retryable:bool -> auth_denied:bool -> t -> t
val mark_keeper_memory_facts_failed :
  at:Clock.Mono.t ->
  ?active_keeper:string ->
  keeper:string ->
  reason:string ->
  retryable:bool ->
  auth_denied:bool ->
  t ->
  t
val apply_keeper_memory_journal :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_knowledge.keeper_memory_journal ->
  t ->
  t
val mark_keeper_memory_journal_failed :
  at:Clock.Mono.t ->
  ?active_keeper:string ->
  keeper:string ->
  reason:string ->
  retryable:bool ->
  auth_denied:bool ->
  t ->
  t
val memory_health_for_keeper :
  keeper:string -> t -> Wire_knowledge.keeper_memory_health_row option
val memory_facts_for_keeper :
  keeper:string -> t -> Wire_knowledge.keeper_memory_facts option
val memory_journal_for_keeper :
  keeper:string -> t -> Wire_knowledge.keeper_memory_journal option
val toggle_fact_category : string -> t -> t
val move_memory_subview_scroll : ?max_scroll:int -> delta:int -> t -> t
val move_facts_selection : count:int -> delta:int -> t -> t

val apply_board_feed_meta : Wire_knowledge.board_feed_meta -> t -> t
val apply_board_thread_meta : Wire_knowledge.board_thread_meta -> t -> t
val post_extras_for : post_id:string -> t -> Wire_knowledge.board_post_extras option
val comment_audience_for :
  post_id:string -> comment_id:string -> t -> string option
val active_comment_page_for :
  post_id:string -> t -> Wire_knowledge.board_comment_page option
val wrapped_comment_lines_count :
  theme:Theme.t ->
  width:int ->
  ?max_body_lines:int ->
  threaded_comment list ->
  int
(** Exact wrapped visual row count (header + wrapped body lines per comment) for
    Board Preview and Thread Dive scroll math. *)
