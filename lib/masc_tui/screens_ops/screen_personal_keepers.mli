(** Multi-Account Personal Keepers workspace screen ([/api/v1/auth/keepers*]).

    Rendered on [4 Keepers] whenever [Rbac.is_multi_account model.auth_session]
    is true, keeping Single-User fleet rendering completely isolated. *)

open Masc_tui_core
open Masc_tui_term
open Masc_tui_store

val render :
  model:Model.t ->
  cache:Masc_tui_ui.Card.Cache.t ->
  rect:Rect.t ->
  Cell_grid.t ->
  unit
