open Masc_tui_types

(* What a press on marked text does. Each constructor is a place a key
   already reaches, so a press never does something the keyboard cannot. *)
type ring_edge = Ring_before | Ring_after

(* [Press_surface] is a Tab-ring entry, or a title-strip entry that is a
   surface of its own (Activity's Events and Logs, Planning's three stops,
   Standalone lanes). [Press_ring_edge] is the count of ring entries hidden
   past one edge of a narrow strip. The rest are the entries of one screen's
   own strip, each named by the value its cycle key steps through. A list row
   is named by its ID, so a refresh that reorders the list cannot move a
   press onto another row. *)
type press_target =
  | Press_surface of surface
  | Press_ring_edge of ring_edge
  | Press_keeper_tab of keeper_detail_tab
  | Press_config_pane of config_pane
  | Press_metrics_section of metrics_section
  | Press_tools_pane of tools_pane
  | Press_memory_category of memory_category_filter
  | Press_theme_filter of [ `All | `Dark | `Light ]
  | Press_runtime_mode of runtime_mode
  | Press_context_tab of Masc_tui_context_inspector.tab
  | Press_keeper_row of string

(* An overlay keeps the surface's strip on its first row, and a press there
   would change the surface under a modal no key can leave that way. The
   Context inspector's own tabs change only the overlay. *)
let press_changes_the_surface = function
  | Press_surface _ | Press_ring_edge _ | Press_keeper_tab _
  | Press_config_pane _ | Press_metrics_section _ | Press_tools_pane _
  | Press_memory_category _ | Press_theme_filter _ | Press_runtime_mode _
  | Press_keeper_row _ ->
      true
  | Press_context_tab _ -> false

(* Marks drawn during the frame being built. The frame's renderer resets it
   before drawing and reads it back once the rows are final. *)
let press_marks : press_target Masc_tui_hit.registry = Masc_tui_hit.registry ()

let pressable target text = Masc_tui_hit.mark press_marks target text
