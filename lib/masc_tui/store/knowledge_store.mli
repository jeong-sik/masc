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
  memory_diff_window : memory_diff_window;
  memory_diff_keeper : string option;
  last_memory_act_answer : (string * Wire_knowledge.memory_act_answer) option;
  selected_index : int;
  scroll_offset : int;
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
val record_memory_act_answer :
  keeper:string -> Wire_knowledge.memory_act_answer -> t -> t

val begin_wiki_edit : Wire_knowledge.wiki_page_detail -> t -> t
val update_wiki_edit_body : string -> t -> t
val update_wiki_edit_note : string -> t -> t
val mark_wiki_edit_saving : bool -> t -> t
val cancel_wiki_edit : t -> t
val wiki_put_request_of_draft :
  wiki_edit_draft -> Wire_knowledge.wiki_put_request

val filtered_posts : t -> Wire_knowledge.board_post list
val quarantines_list : t -> Wire_knowledge.quarantine_candidate list
val selected_post : t -> Wire_knowledge.board_post option
val selected_wiki_page : t -> Wire_knowledge.wiki_page_summary option
val selected_artifact : t -> Wire_knowledge.artifact_entry option

val move_selection : delta:int -> t -> t
val set_filter : string -> t -> t
val mark_stale_all : t -> t
