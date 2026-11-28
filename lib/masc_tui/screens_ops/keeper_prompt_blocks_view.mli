(** Prompt Blocks subtab of the Keeper context inspector.

    Lists the selected turn's prompt blocks in assembly order from its turn
    record, and shows a block's text from the keeper's last prompt capture
    when the capture holds that block with the same sha256. *)

open Masc_tui_core
open Masc_tui_term
open Masc_tui_store

val block_name : Prompt_block_id.t -> Say.t
(** The operator's name for an injection site. *)

val draw :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  model:Model.t ->
  st:Keeper_context_store.keeper_state ->
  unit
