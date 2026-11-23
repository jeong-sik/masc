(** Where one Keeper's current Memory OS snapshot lives under the Keepers
    directory, and the basis join helper.

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_types

val suffix : string

val merge_basis : basis -> basis -> basis

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string
