(** Keeper_coordination — Coord presence and room cursor management. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val room_cursor_for : keeper_meta -> string -> int

val set_room_cursor : keeper_meta -> string -> int -> keeper_meta

val room_ids_for_meta : Coord.config -> keeper_meta -> string list

val ensure_keeper_room_presence
  :  Coord.config
  -> keeper_meta
  -> keeper_meta * Keeper_context_runtime.room_presence_error list
