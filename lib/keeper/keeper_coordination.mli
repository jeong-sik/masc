(** Keeper_coordination — Coord presence and room cursor management. *)

open Keeper_types

val room_cursor_for : keeper_meta -> string -> int

val set_room_cursor : keeper_meta -> string -> int -> keeper_meta

val room_ids_for_meta : Coord.config -> keeper_meta -> string list

val ensure_keeper_room_presence : Coord.config -> keeper_meta -> keeper_meta
