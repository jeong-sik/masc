(** The Keeper chat surface.

    The definitions only this surface reaches, computed from the call graph
    and closed: nothing here belongs to another screen. 53 of the 60
    stay inside -- they are what the exported ones are built from. *)

module Frame_presenter = Masc_tui_frame_presenter
module Message_layout = Masc_tui_message_layout

val chat_row_action_at : row:int -> Message_layout.row_action

type chat_markdown_identity = {
  cmi_style : Message_layout.style;
  cmi_keeper_name : string;
  cmi_request_id : string;
  cmi_observed_at : float option;
  cmi_entry_index : int;
}

val keeper_health_word :
  Masc_tui_types.Tui_decode.keeper_health option -> string

val keeper_message_find_scroll :
  Masc_tui_types.state ->
  keeper_name:String.t ->
  needle:String.t ->
  older_than:Masc_tui_types.msg_anchor option ->
  (int * Masc_tui_types.msg_anchor) option

type log_block = {
  lb_log : Masc_tui_types.turn_log;
  lb_request_id : string;
  lb_insertion : int;
  lb_entries : Message_layout.entry list;
}

type tagged_row =
    Tagged_row of Masc_tui_types.msg_entry
  | Tagged_block of Masc_tui_types.turn_log

val render_keeper_message :
  Masc_tui_types.state ->
  Masc_tui_render_prim.Frame_presenter.frame *
  Masc_tui_types.clamped_scroll option
