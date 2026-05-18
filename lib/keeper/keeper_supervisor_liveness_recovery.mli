(** Dead-keeper liveness recovery scan. *)

open Keeper_types

type credential_recovery_outcome =
  | Credential_recovery_not_needed
  | Credential_recovery_reissued of string
  | Credential_recovery_failed of string

val credential_recovery_before_restart_for_test
  :  base_path:string
  -> Keeper_registry.registry_entry
  -> credential_recovery_outcome

val scan
  :  supervise_keepalive:(proactive_warmup_sec:int -> 'a context -> keeper_meta -> unit)
  -> publish_lifecycle:
       (event:Keeper_lifecycle_events.lifecycle_event -> string -> string -> unit -> unit)
  -> 'a context
  -> unit
