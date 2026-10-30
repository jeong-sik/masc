(** Resolves the exact Keeper entry and carries a live publication provider
    into one admitted turn without opening a recovery store. *)

type failure =
  | Registry_entry_not_found of
      { base_path : string
      ; keeper_name : string
      }
  | Registry_entry_unhealthy of Keeper_registry.registry_entry_health

val failure_to_string : failure -> string

type turn_resources =
  { entry : Keeper_registry.registry_entry
  ; publication_recovery :
      Keeper_publication_recovery_availability.turn_context
  }

val resolve_turn_resources
  :  provider:Keeper_publication_recovery_availability.provider
  -> base_path:string
  -> keeper_name:string
  -> (turn_resources, failure) result
(** Performs only the exact in-memory Keeper registry lookup. The provider is
    not read here. File edit/write dispatch re-reads it at the moment of the
    effect and executes the write inside [Fs_compat.Publication_recovery.with_lane]'s
    callback. Consequently an idle, read-only, or non-file turn performs no
    publication-recovery filesystem acquisition. *)
