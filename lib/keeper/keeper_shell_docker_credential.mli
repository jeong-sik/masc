(** Docker credential mount/env resolution.

    Translates [git_creds_enabled] into the Docker [-v] mount fragments
    and [-e] env fragments needed to forward the keeper's resolved
    identity into a container.  Pure logic: no I/O, no container state. *)

open Keeper_types

val resolve :
  config:Coord.config ->
  meta:keeper_meta ->
  git_creds_enabled:bool ->
  (string list * string list, string) result
