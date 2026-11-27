(** Account/Session overlay renderer ({!Masc_tui_core.Nav.Account}):
    server mode, authenticated principal, binding, resolved role, exact
    6-capability matrix, masked runtime Bearer/PAT editor, and Multi-Account
    own-provider inspection/management. *)

open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_store

val render :
  Cell_grid.t ->
  cache:Card.Cache.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  model:Model.t ->
  unit
