(** Overlay and modal screens (About, Keeper navigation, Context inspector,
    Command palette, Patch review, Link preview, Play invite card, Keeper
    deletions, Cheat sheet, Agenda, Answering, Terminal-too-small, Account
    login, Collab, and Lane add-ons) and their viewport calculators. *)

val detail_reading_width : int -> int
(** Content width in terminal cells for a detail reader, given the terminal's
    column count. Async preparation and the overlay renderer share this value. *)

val detail_reading_viewport :
  Masc_tui_types.state -> Masc_tui_detail_reading.t -> int * int

val render_detail_reading :
  Masc_tui_types.state -> Masc_tui_detail_reading.t ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_about :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_keeper_navigation :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val context_inspector_viewport : Masc_tui_types.state -> int * int

val context_inspector_detail_viewport : Masc_tui_types.state -> int * int

val render_context_inspector :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val help_viewport : Masc_tui_types.state -> int * int

val render_palette :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val patch_modal_horizontal_limit : Masc_tui_types.state -> int

val patch_modal_viewport : Masc_tui_types.state -> int * int

val render_patch_modal :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val link_modal_viewport : Masc_tui_types.state -> int * int

val render_link_preview_modal :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_play_card :
  Masc_tui_types.state ->
  Masc_tui_play_card.t ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val keeper_deletions_viewport : Masc_tui_types.state -> int * int

val render_keeper_deletions :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_help :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val agenda_lines : Masc_tui_types.state -> Masc_tui_agenda.line list

val agenda_viewport : Masc_tui_types.state -> int * int

val agenda_scroll_position : Masc_tui_types.state -> int

val answering_viewport : Masc_tui_types.state -> int * int

val answering_selected_target :
  Masc_tui_types.state -> lines:Masc_tui_answering.line list -> string option

val render_answering :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_agenda :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_terminal_too_small :
  Masc_tui_types.state ->
  rows:int ->
  cols:int ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_account_login :
  Masc_tui_types.state ->
  Masc_tui_account_login.t ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_collab :
  Masc_tui_types.state ->
  Masc_tui_collab.t ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_lane_addons :
  Masc_tui_types.state ->
  Masc_tui_lane_addons.t ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
