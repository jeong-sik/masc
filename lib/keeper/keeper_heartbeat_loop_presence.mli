(** Presence and identity sync helpers for the keeper heartbeat loop. *)

val effective_keepalive_meta :
  base_path:string ->
  fallback:Keeper_meta_contract.keeper_meta ->
  disk_meta_opt:Keeper_meta_contract.keeper_meta option ->
  Keeper_meta_contract.keeper_meta
(** Pick the freshest keeper meta available for keepalive publication. *)

val keeper_agent_status : Keeper_meta_contract.keeper_meta -> Masc_domain.agent_status
(** Project keeper meta into the public agent status enum. *)

val sync_keeper_presence :
  ctx:'a Keeper_types_profile.context ->
  registry_entry:Keeper_registry.registry_entry ->
  meta_current:Keeper_meta_contract.keeper_meta ->
  consecutive_failures:int ref ->
  Keeper_meta_contract.keeper_meta
(** Publish keeper heartbeat presence and update failure counters. A successful
    sync clears the typed heartbeat failure reason; existing turn-failure debt
    is restored as its own typed count. Recovery is conditional on the
    originating registry lane still owning the name. *)
