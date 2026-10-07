(** Keeper chat rendering and shared message layout. *)

module Frame_presenter = Masc_tui_frame_presenter
module Message_layout = Masc_tui_message_layout

val chat_row_action_at : row:int -> Message_layout.row_action

val keeper_health_word :
  Masc_tui_types.Tui_decode.keeper_health option -> string

val keeper_message_find_scroll :
  Masc_tui_types.state ->
  keeper_name:String.t ->
  needle:String.t ->
  older_than:Masc_tui_types.chat_search_cursor option ->
  (Masc_tui_types.chat_scroll_position * Masc_tui_types.chat_search_cursor) option

val render_keeper_message :
  Masc_tui_types.state ->
  Masc_tui_render_prim.Frame_presenter.frame *
  Masc_tui_types.clamped_scroll option

(** Layout and body rendering share the final body budget. *)
val keeper_message_layout_entries :
  ?messages:Masc_tui_types.msg_entry list -> Masc_tui_types.state ->
  keeper_name:string -> chat_cols:int -> Message_layout.entry list

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
  val chat_markdown_cache : chat_markdown_identity Masc_tui_markdown_render_cache.t
  val chat_markdown_theme_revision : int
end
