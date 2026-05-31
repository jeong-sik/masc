(** Keeper_coordination — Coord presence bootstrap. *)

open Keeper_types
open Keeper_meta_contract

val ensure_keeper_room_presence
  :  Coord.config
  -> keeper_meta
  -> keeper_meta * Keeper_context_runtime.room_presence_error list
