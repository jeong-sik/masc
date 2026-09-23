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
  older_than:Masc_tui_types.msg_anchor option ->
  (int * Masc_tui_types.msg_anchor) option

val render_keeper_message :
  Masc_tui_types.state ->
  Masc_tui_render_prim.Frame_presenter.frame *
  Masc_tui_types.clamped_scroll option

(** Layout and body rendering share the final body budget. *)
val keeper_message_layout_entries :
  ?messages:Masc_tui_types.msg_entry list -> Masc_tui_types.state ->
  keeper_name:string -> chat_cols:int -> Message_layout.entry list

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
