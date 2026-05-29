(** Alive-but-stuck supervisor detector and recovery request. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val scan : 'a context -> unit

val request_recovery_for_test
  :  base_path:string
  -> elapsed:float
  -> Keeper_registry.registry_entry
  -> unit

val reset_for_test : unit -> unit
