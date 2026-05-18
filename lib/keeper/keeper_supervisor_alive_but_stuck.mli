(** Alive-but-stuck supervisor detector and recovery request. *)

open Keeper_types

val scan : 'a context -> unit

val request_recovery_for_test
  :  base_path:string
  -> elapsed:float
  -> Keeper_registry.registry_entry
  -> unit

val reset_for_test : unit -> unit
