(** Per-Turn Keeper Context Inspector & Per-Keeper Tool Calls views.

    Mounts into BOTH [Keepers] Split right pane and zoomed full-screen [Keepers]
    for [Nav.Keeper_context] and [Nav.Keeper_tool_calls]. Pure [Cell_grid]
    rendering over {!Masc_tui_ui} primitives with zero raw ANSI. *)

open Masc_tui_core
open Masc_tui_term
open Masc_tui_store

val draw_context_tab :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  model:Model.t ->
  name:string ->
  unit

val draw_tool_calls_tab :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  model:Model.t ->
  name:string ->
  unit
