(** What a press on marked text does, and the marks of the frame being drawn.
    Every renderer that draws a pressable strip marks through {!pressable};
    {!Masc_tui_render.render} resets {!press_marks} before drawing and reads
    it back from the finished rows. *)

type ring_edge = Ring_before | Ring_after

(** Each constructor names a place a key already reaches. [Press_surface] is
    a Tab-ring entry or a title-strip entry that is a surface of its own;
    [Press_ring_edge] is the count of ring entries hidden past an edge of a
    narrow strip; the rest are the entries of one screen's own strip. *)
type press_target =
  | Press_surface of Masc_tui_types.surface
  | Press_ring_edge of ring_edge
  | Press_keeper_tab of Masc_tui_types.keeper_detail_tab
  | Press_config_pane of Masc_tui_types.config_pane
  | Press_metrics_section of Masc_tui_types.metrics_section
  | Press_tools_pane of Masc_tui_types.tools_pane
  | Press_memory_category of Masc_tui_types.memory_category_filter
  | Press_theme_filter of [ `All | `Dark | `Light ]
  | Press_runtime_mode of Masc_tui_types.runtime_mode
  | Press_standalone_lanes
  | Press_context_tab of Masc_tui_context_inspector.tab
  | Press_keeper_row of string  (** a Keepers list row, by Keeper name *)

val press_changes_the_surface : press_target -> bool
(** Whether a press changes what the surface shows. Only the Context
    inspector's own tabs do not; those are the presses an overlay keeps. *)

val press_marks : press_target Masc_tui_hit.registry

val pressable : press_target -> string -> string
(** [pressable target text] is [text] marked so that a press on it resolves
    to [target] in the frame it is drawn in. *)
