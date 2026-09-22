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

val cached_chat_markdown :
  link_previews_mode:[ `Rich | `Compact | `Off ] ->
  theme:Masc_tui_ansi.Chat_theme.snapshot -> entry:Message_layout.entry ->
  width:int -> string list
