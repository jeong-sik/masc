(** Infra › Code › Review: the changed-file list and the selected change's diff. *)

open Masc_tui_core
open Masc_tui_term
open Masc_tui_store

val draw_changes :
  model:Model.t -> grid:Cell_grid.t -> rect:Rect.t -> theme:Theme.t -> unit
(** Changed files of the current scope, with the review selection highlighted. *)

val draw_diff :
  model:Model.t ->
  grid:Cell_grid.t ->
  hdr_rect:Rect.t ->
  vis_rect:Rect.t ->
  theme:Theme.t ->
  unit
(** The selected change's diff from {!Infra_store.review_diff_rows}: one column
    below {!Code_review_layout.side_by_side_min_cols}, old and new side by side
    from there. *)
