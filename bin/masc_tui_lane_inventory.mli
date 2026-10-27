(** Plain, unwrapped display text. The renderer sanitizes terminal text and
    measures/wraps cells. These functions perform no I/O or state mutation. *)
val row_category : Masc.Tui_decode_lane_inventory.row -> Masc.Lane_addon_category.t option
(** Built-ins read the server-authored role. A configured package uses only its
    current valid declaration; a manual row uses its exact original instance.
    Invalid, absent and unobserved declarations never borrow worker metadata.
    [None] is unclassified display metadata, not an activity permission. *)
type overview_entry =
  | Category_header of Masc.Lane_addon_category.t option
  | Lane_row of Masc.Tui_decode_lane_inventory.row
val overview_entries : Masc.Tui_decode_lane_inventory.row list -> overview_entry list
(** Nonempty role groups, each with a nonselectable header. Original row
    objects and their order within a group are preserved. *)
val ordered_rows : Masc.Tui_decode_lane_inventory.row list -> Masc.Tui_decode_lane_inventory.row list
(** The selectable rows in the same grouping as [overview_entries]. *)
val category_label : Masc.Lane_addon_category.t option -> string
val row_position : id:string -> overview_entry list -> int option
(** Visual position of the exact row ID, including headers, or [None] if absent. *)
type identity
val identity : Masc.Tui_decode_lane_inventory.row -> identity
val find_identity : identity -> Masc.Tui_decode_lane_inventory.row list -> Masc.Tui_decode_lane_inventory.row option
val identity_index : identity -> Masc.Tui_decode_lane_inventory.row list -> int option
(** Selection retains the row ID and closed target; a declaration also retains
    its valid installation ID, and a manual target includes its incarnation.
    A missing or replaced original has no selected target. Category and worker
    status changes alone do not change this identity. *)
val row_summary : Masc.Tui_decode_lane_inventory.row -> string
(** Where a browser source is switched on or off, for a Browser row. *)
val browser_switch_line : string
(** Machine activity is displayed independently of its retained publication. *)
val row_standing : Masc.Tui_decode_lane_inventory.row -> Masc_tui_lane_standing.t
(** How the row stands. A package row with a failed worker is [Failing]
    whatever its declaration says; otherwise the declaration's application
    decides, and without a usable declaration its workers do. Something
    switched off that still has work in flight is [Changing]. *)
val row_standing_in : Masc.Tui_decode_lane_inventory.snapshot -> Masc.Tui_decode_lane_inventory.row -> Masc_tui_lane_standing.t
(** [row_standing], with an exact row's run observation from the same
    capture: a degraded lane is [Failing], one switched off that is still
    finishing runs is [Changing]. *)
val detail_lines : Masc.Tui_decode_lane_inventory.row -> string list
val refused_cli_slot_lines :
  Masc.Keeper_lane_cli_oneshot.refused_slot list -> string list
val overview_notices : Masc.Tui_decode_lane_inventory.snapshot -> string list
(** Owner/completeness notices and an issue count; full diagnostics stay in
    [snapshot_notices] so they do not displace the selectable overview. *)
val snapshot_notices : Masc.Tui_decode_lane_inventory.snapshot -> string list
val family_label : Masc.Tui_decode_lane_inventory.selection -> string

val row_summary_in : Masc.Tui_decode_lane_inventory.snapshot -> Masc.Tui_decode_lane_inventory.row -> string
(** Exact rows retain their run observation from the same inventory capture. *)

(** A Lane Add-on package row's exact outputs (RFC operator-quiz §4.8). The
    chosen output is named by [selected], the output name last chosen in this
    row; [None], or a name the row no longer lists, chooses the first. *)
val selected_exact_output :
  selected:string option -> Masc.Tui_decode_lane_inventory.row ->
  (string * Masc.Tui_decode_lane_inventory.exact_output) option
(** The installation id and the chosen output; [None] for a row with no exact output. *)
val step_exact_output :
  selected:string option -> direction:int -> Masc.Tui_decode_lane_inventory.row -> (string * string) option
(** The installation id and the output name [direction] steps away from the
    chosen one; the first and last stay where they are. *)
val exact_output_table_path :
  installation_id:string -> Masc.Tui_decode_lane_inventory.exact_output -> (string list, string) result
(** The [runtime.addon_exact_lanes.<installation id>.<output>] table path, or
    why runtime.toml cannot name it. *)
val exact_output_lines : selected:string option -> Masc.Tui_decode_lane_inventory.row -> string list
