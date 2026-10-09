(** Keeper chat rendering and shared message layout. *)

module Frame_presenter = Masc_tui_frame_presenter
module Message_layout = Masc_tui_message_layout

val chat_row_action_at : row:int -> Message_layout.row_action

val keeper_health_word :
  Masc_tui_types.Tui_decode.keeper_health option -> string

type chat_search_result = {
  match_result : (Masc_tui_types.chat_scroll_position * Masc_tui_types.chat_search_cursor) option;
  unavailable_entries : int;
}

val keeper_message_find_scroll :
  ?preview_lookup:(string -> Masc_tui_link_preview.og_preview) ->
  Masc_tui_types.state ->
  keeper_name:String.t ->
  needle:String.t ->
  older_than:Masc_tui_types.chat_search_cursor option ->
  chat_search_result

val render_keeper_message :
  Masc_tui_types.state ->
  Masc_tui_render_prim.Frame_presenter.frame *
  Masc_tui_types.clamped_scroll option

val keeper_message_layout_entries :
  ?messages:Masc_tui_types.msg_entry list -> Masc_tui_types.state ->
  keeper_name:string -> chat_cols:int -> Message_layout.entry list
(** History/session rows only, using the final body budget. Live and held
    execution logs are merged by {!keeper_message_projection}. *)

type tagged_row
(** The conversation row's structural provenance, private to the renderer. *)

type chat_projection = private {
  tagged_entries : (tagged_row * Message_layout.entry) list;
      (** Merged history and observed conversation, including live/held
          execution. The prefix searched by the pane. *)
  transient_anchors : Masc_tui_types.chat_scroll_anchor option list;
      (** One per entry after that prefix: the scroll anchor of a pending
          input or polled excerpt, when it has one. *)
  layout_entries : Message_layout.entry list;
      (** The same prefix followed by pending input and polled excerpts.
          The complete sequence measured and drawn by the pane. *)
}

val keeper_message_projection :
  Masc_tui_types.state -> keeper_name:string -> chat_cols:int -> chat_projection
(** The shared frame/search projection, before physical row wrapping and
    viewport clipping. Authored bodies and execution rails remain typed. *)

val search_anchor_of_tag : tagged_row -> Masc_tui_types.chat_search_anchor option
(** The durable search identity of a row; [None] for a block row that has no
    drawn origin. *)

val projection_index_of_anchor :
  chat_projection -> Masc_tui_types.chat_search_anchor -> int option
(** The first entry the anchor matches, by the same identity, user turn slot,
    reply and journal-origin keys as typed matching; [None] when no entry
    carries the anchor. *)

type scroll_anchor_index
(** Every entry's scroll anchor by position, built once per projection. *)

val scroll_anchor_index : chat_projection -> scroll_anchor_index
(** The index for this projection. The same value is returned while
    [layout_entries] is the same list. *)

val scroll_anchor_at :
  chat_projection -> int -> Masc_tui_types.chat_scroll_anchor option
(** The anchor of the entry at a position; [None] outside the projection. *)

val with_transient_tail :
  Message_layout.entry list -> transient:Message_layout.entry list ->
  Message_layout.entry list
(** The settled entries followed by the pending and polled ones. With nothing
    transient this is the settled list itself, not a copy: the layout reuses
    its row counts only for the list it measured. *)

val chat_tail_entries :
  Masc_tui_types.state -> keeper_name:string -> role_label_column:int ->
  Message_layout.entry list
(** Pending inputs with delivery state in their labels and original text in
    their bodies, preceded by the pending-section status entry. *)

val polled_turn_output_entries :
  Masc_tui_types.state -> keeper_name:string -> role_label_column:int ->
  Message_layout.entry list
(** A polled output excerpt and its separate observation status. Empty when
    the journal already supplies the turn's text. *)

val chat_body_with_previews :
  preview:(string -> Masc_tui_link_preview.og_preview) ->
  mode:[ `Rich | `Compact | `Off ] -> entry:Message_layout.entry ->
  width:int -> string

val skill_tone_of_state :
  Masc_tui_keeper_chat_transcript.skill_state -> Message_layout.skill_tone
(** Which mark a skill row wears for a given state. Exposed because it is a
    contract rather than a detail of drawing: the words on the row and the
    mark beside it answer different questions, and a state landing in the
    wrong tone makes the mark say something the row does not
    ([Skill_delivered] drew live, so a finished line read as a working one).
    [test_tui_chat_queue_wiring] pins the whole table, so a new state has to
    choose a tone rather than inherit one. *)

val cached_chat_markdown :
  link_previews_mode:[ `Rich | `Compact | `Off ] ->
  theme:Masc_tui_ansi.Chat_theme.snapshot -> entry:Message_layout.entry ->
  width:int -> string list

val keeper_message_clock : float -> string
(** The wall-clock stamp the live heading prints, so a test can locate the
    stamp between bodies without reading it back off a rendered frame. *)

(** Regression access to fold measurement and its production cache owner. *)
module For_testing : sig
  type chat_markdown_identity =
  { cmi_style : Message_layout.style;
    cmi_keeper_name : string;
    cmi_request_id : string;
    cmi_observed_at : float option;
    cmi_entry_index : int;
  }
  val chat_markdown : context:Masc_tui_ansi.Chat_theme.body_context ->
    width:int -> string -> string list
  val fold_thinking_entry : Masc_tui_types.state -> chat_cols:int ->
    Message_layout.entry -> Message_layout.entry
  val thinking_height_cache : chat_markdown_identity Masc_tui_markdown_render_cache.t
  val chat_markdown_cache : chat_markdown_identity Masc_tui_markdown_render_cache.t
  val chat_markdown_theme_revision : int
  val source_index_build_count : unit -> int
  val source_url_discovery_count : unit -> int
end
