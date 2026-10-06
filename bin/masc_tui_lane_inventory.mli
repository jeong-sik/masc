(** Plain, unwrapped display text. The renderer sanitizes terminal text and
    measures/wraps cells. These functions perform no I/O or state mutation. *)
val row_summary : Masc.Tui_decode_lane_inventory.row -> string
val detail_lines : Masc.Tui_decode_lane_inventory.row -> string list
val overview_notices : Masc.Tui_decode_lane_inventory.snapshot -> string list
(** Owner/completeness notices and an issue count; full diagnostics stay in
    [snapshot_notices] so they do not displace the selectable overview. *)
val snapshot_notices : Masc.Tui_decode_lane_inventory.snapshot -> string list
val family_label : Masc.Tui_decode_lane_inventory.selection -> string

val row_summary_in : Masc.Tui_decode_lane_inventory.snapshot -> Masc.Tui_decode_lane_inventory.row -> string
(** Exact rows retain their run observation from the same inventory capture. *)
