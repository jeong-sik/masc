(** What a press on marked text does, and the marks of the frame being drawn.
    Every renderer that draws a pressable strip marks through {!pressable};
    {!Masc_tui_render.render} resets {!press_marks} before drawing and reads
    it back from the finished rows. *)

type ring_edge = Ring_before | Ring_after

type queue_selection
(** The selected Queue row and its workspace, read and action authority at
    the time the frame was drawn. *)

(** Each constructor names a place a key already reaches. [Press_surface] is
    a Tab-ring entry or a title-strip entry that is a surface of its own;
    [Press_ring_edge] is the count of ring entries hidden past an edge of a
    narrow strip; [Press_keeper_row] is a Keepers list row, by Keeper name;
    the rest are the entries of one screen's own strip. *)
type press_target =
  | Press_surface of Masc_tui_types.surface
  | Press_ring_edge of ring_edge
  | Press_keeper_tab of Masc_tui_types.keeper_detail_tab
  | Press_config_pane of Masc_tui_types.config_pane
  | Press_metrics_section of Masc_tui_types.metrics_section
  | Press_tools_pane of Masc_tui_types.tools_pane
  | Press_memory_category of Masc_tui_types.memory_category_filter
  | Press_theme_filter of [ `All | `Dark | `Light ]
  | Press_ui_language
  | Press_runtime_mode of Masc_tui_types.runtime_mode
  | Press_standalone_lanes
  | Press_context_tab of Masc_tui_context_inspector.tab
  | Press_keeper_row of string  (** a Keepers list row, by Keeper name *)
  | Press_chat_call of Masc_tui_types.workspace_authority * unit ref * string * string
  | Press_lane_row of Masc_tui_lane_inventory.identity
      (** The frame's original row ID and typed installation/incarnation target. *)
  | Press_queue_selected of queue_selection
      (** The selected row of a Queue list, if that row reached the frame. *)
  | Press_input_rejection of Masc_tui_action_notice.rejection
      (** Evidence of the complete rejection notice, not a clickable action. *)

val press_changes_the_surface : press_target -> bool
(** Whether a press changes what the surface shows. An overlay keeps its own
    Context tabs and Queue targets. *)

val press_is_interactive : press_target -> bool
(** Evidence-only marks must not hide a real click target underneath them. *)

val press_marks : press_target Masc_tui_hit.registry

val pressable : press_target -> string -> string
(** [pressable target text] is [text] marked so that a press on it resolves
    to [target] in the frame it is drawn in. *)

val queue_selection_for_item :
  Masc_tui_types.state -> Masc_tui_types.queue_panel ->
  Masc_tui_queue_inspection.item -> queue_selection option
(** Capture the item's full observed text and the authorities of this frame. *)

val queue_selection_visible : inner_width:int -> marker:string -> text:string -> bool
(** Whether fitting the selected row leaves its marker and some nonblank item
    text visible. A row may be shortened without losing its authority. *)

val presented_queue_selection : press_target Masc_tui_hit.zones -> queue_selection option
(** Find the Queue selection that made it into the frame's final cells. *)

val queue_owner_matches : Masc_tui_types.state -> Masc_tui_types.queue_panel -> Masc_tui_types.queue_panel_owner -> bool
(** Match the list or detail owner of a presented Queue to the current panel. *)

val queue_owner_authority_changed :
  presented:Masc_tui_types.queue_panel_owner option -> candidate:Masc_tui_types.queue_panel_owner option -> bool
(** Whether the Queue owner changed, including its physical read identity. *)

val play_card_matches :
  presented:Masc_tui_play_card.t option -> current:Masc_tui_play_card.t option -> bool
(** Only the same card object as the accepted frame grants input authority. *)
val play_owner_authority_changed :
  presented:Masc_tui_play_card.t option -> candidate:Masc_tui_play_card.t option -> bool
(** Whether the exact Play card object changed. Its credential stays in the card. *)

type queue_play_input_owner =
  | Queue_input of Masc_tui_types.queue_panel
  | Play_input
  | Wait_for_frame
  | Other_input

val queue_play_input_owner :
  play_presented:Masc_tui_play_card.t option -> play_shown:Masc_tui_play_card.t option -> compact:bool ->
  state:Masc_tui_types.state -> beneath:Masc_tui_types.queue_panel option ->
  presented_queue:Masc_tui_types.queue_panel_owner option -> queue_play_input_owner
(** Choose who may receive input across the Queue/Play presentation boundary.
    [beneath] is the Queue under Play after normal overlay priority. *)

val queue_selection_authority_changed :
  presented:press_target Masc_tui_hit.zones -> candidate:press_target Masc_tui_hit.zones -> bool
(** Whether the Queue selection carried by a candidate frame differs from the
    one the terminal last accepted, including hidden identity and text. *)

val resolve_queue_selection :
  require_action_ready:bool -> state:Masc_tui_types.state ->
  panel:Masc_tui_types.queue_panel -> items:Masc_tui_queue_inspection.item list ->
  queue_selection -> Masc_tui_queue_inspection.item_id option
(** Resolve a painted selection only if it is still the current selected row
    with the same text and authorities. Changes also require action readiness. *)

val presented_input_rejection :
  rows:int -> cols:int -> press_target Masc_tui_hit.zones ->
  Masc_tui_action_notice.rejection option
(** Only an explicitly closed, full-width mark inside the presented frame
    proves that the rejection notice reached the terminal. *)
