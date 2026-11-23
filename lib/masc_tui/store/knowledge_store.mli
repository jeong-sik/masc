(** Knowledge domain sub-store: Signal-first Board ([signal_only = true] by
    default), succession chain expand set, Quarantine list, Wiki index/page/
    log/search/lint + inline edit draft, Artifacts, World Memory conflicts +
    Librarian writer recovery acts, and Temporal Memory Diff
    ([24h | 7d | 30d | revs]). *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_set : Set.S with type elt = string

type memory_diff_window =
  | Window_24h
  | Window_7d
  | Window_30d
  | Window_revs of { from_rev : int; to_rev : int }

type wiki_edit_draft = {
  slug : string;
  expected_revision : int option;
  expected_sha256 : string option;
  title : string;
  summary : string;
  source : Wire_knowledge.wiki_source;
  tags : string list;
  body : string;
  note : string;
  dirty : bool;
  saving : bool;
}

type t = {
  active_tab : Nav.knowledge_tab;
  board : Wire_knowledge.board_feed Observed.t;
  board_signal_only : bool;
  board_sort_by : string;
  board_hearth : string option;
  expanded_succession_chains : String_set.t;
  active_thread :
    (Wire_knowledge.board_post * Wire_knowledge.board_comment list) Observed.t;
  quarantines : Wire_knowledge.quarantine_candidate list Observed.t;
  wiki_artifacts_submode : [ `Wiki | `Artifacts ];
  wiki_index : Wire_knowledge.wiki_index Observed.t;
  wiki_page : Wire_knowledge.wiki_page_detail Observed.t;
  wiki_log : Wire_knowledge.wiki_log_response Observed.t;
  wiki_search : Wire_knowledge.wiki_search_response Observed.t;
  wiki_lint : Wire_knowledge.wiki_lint_report Observed.t;
  wiki_edit_draft : wiki_edit_draft option;
  artifacts : Wire_knowledge.artifact_entry list Observed.t;
  world_memory : Wire_knowledge.world_memory Observed.t;
  memory_diff : Wire_knowledge.memory_diff Observed.t;
  memory_os_internals : Wire_knowledge.memory_os_internals Observed.t;
  memory_diff_window : memory_diff_window;
  memory_diff_keeper : string option;
  last_memory_act_answer : (string * Wire_knowledge.memory_act_answer) option;
  selected_index : int;
  scroll_offset : int;
  diff_scroll_offset : int;
  detail_scroll_offset : int;
  pulse_thread_index : int;
  filter_query : string;
}

val empty : t

val memory_diff_window_query : memory_diff_window -> string option
val equal_memory_diff_window : memory_diff_window -> memory_diff_window -> bool

val set_tab : Nav.knowledge_tab -> t -> t
val cycle_tab : Keymap.cycle_dir -> t -> t
val toggle_wiki_artifacts_submode : t -> t

val toggle_signal_only : t -> t
val set_board_sort : string -> t -> t
val toggle_succession_chain : root_id:string -> t -> t
val is_succession_chain_expanded : root_id:string -> t -> bool

val set_memory_diff_window : memory_diff_window -> t -> t
val cycle_memory_diff_window : t -> t
val set_memory_diff_keeper : string option -> t -> t

val apply_board :
  observed_at:Clock.Mono.t -> Wire_knowledge.board_feed -> t -> t
val apply_thread :
  observed_at:Clock.Mono.t ->
  Wire_knowledge.board_post * Wire_knowledge.board_comment list ->
  t ->
  t
val apply_quarantines :
  observed_at:Clock.Mono.t -> Wire_knowledge.quarantine_candidate list -> t -> t
val apply_wiki_index :
  observed_at:Clock.Mono.t -> Wire_knowledge.wiki_index -> t -> t
val apply_wiki_page :
  observed_at:Clock.Mono.t -> Wire_knowledge.wiki_page_detail -> t -> t
val apply_wiki_log :
  observed_at:Clock.Mono.t -> Wire_knowledge.wiki_log_response -> t -> t
val apply_wiki_search :
  observed_at:Clock.Mono.t -> Wire_knowledge.wiki_search_response -> t -> t
val apply_wiki_lint :
  observed_at:Clock.Mono.t -> Wire_knowledge.wiki_lint_report -> t -> t
val apply_artifacts :
  observed_at:Clock.Mono.t -> Wire_knowledge.artifact_entry list -> t -> t
val apply_world_memory :
  observed_at:Clock.Mono.t -> Wire_knowledge.world_memory -> t -> t
val apply_memory_diff :
  observed_at:Clock.Mono.t -> Wire_knowledge.memory_diff -> t -> t
val apply_memory_os_internals :
  observed_at:Clock.Mono.t -> Wire_knowledge.memory_os_internals -> t -> t
val record_memory_act_answer :
  keeper:string -> Wire_knowledge.memory_act_answer -> t -> t

val begin_wiki_edit : Wire_knowledge.wiki_page_detail -> t -> t
val update_wiki_edit_body : string -> t -> t
val update_wiki_edit_note : string -> t -> t
val mark_wiki_edit_saving : bool -> t -> t
val cancel_wiki_edit : t -> t
val wiki_put_request_of_draft :
  wiki_edit_draft -> Wire_knowledge.wiki_put_request

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

val quarantines_list : t -> Wire_knowledge.quarantine_candidate list
val filtered_memory_conflicts : t -> Wire_knowledge.memory_conflict list
val filtered_memory_claims : t -> Wire_knowledge.world_claim list
val filtered_librarian_writers : t -> Wire_knowledge.librarian_writer_row list
val memory_diff_matches_filter : t -> string -> bool

type memory_diff_item =
  | Keeper_added of Wire_knowledge.memory_fact_entry
  | Keeper_updated of Wire_knowledge.memory_updated_fact
  | Keeper_retracted of Wire_knowledge.memory_retracted_fact
  | Keeper_invalidated of Wire_knowledge.memory_invalidated_fact
  | World_added of Wire_knowledge.world_change_entry
  | World_updated of Wire_knowledge.world_updated_entry
  | World_retracted of Wire_knowledge.world_change_entry

val filtered_memory_diff_items : t -> memory_diff_item list
(** Single-SSOT filtered diff items shared by [Screen_knowledge] and
    {!Update_nav} (matching [inv.missing_premise_ids] too). *)

val memory_diff_entry_count : t -> int
val memory_diff_line_count : t -> int
(** Exact flattened visual line count of {!filtered_memory_diff_items} for
    line-level scrolling in [3 Knowledge > Memory] and [Memory_diff_dive]. *)

val keeper_memory_diff_line_count : name:string -> t -> int
(** Exact rendered line count for [Keeper_memory] tab when [memory_diff]
    matches [Scope_keeper name]. *)

val hottest_signal_threads : t -> Wire_knowledge.board_post list
val selected_pulse_thread : t -> Wire_knowledge.board_post option
val move_pulse_thread : ?viewport_rows:int -> delta:int -> t -> t
val selected_post : t -> Wire_knowledge.board_post option
val selected_wiki_page : t -> Wire_knowledge.wiki_page_summary option
val selected_artifact : t -> Wire_knowledge.artifact_entry option

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
