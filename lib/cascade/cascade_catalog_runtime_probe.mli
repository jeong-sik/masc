(** Provider liveness probe helpers for cascade catalog snapshots. *)

val profile_probes :
  Cascade_catalog_runtime_cache.candidate_runtime list ->
  Cascade_catalog_runtime_cache.candidate_probe list

val attach_probe_results :
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  Cascade_catalog_runtime_cache.profile_snapshot list ->
  Cascade_catalog_runtime_cache.profile_snapshot list

val record_probe_metrics :
  Cascade_catalog_runtime_cache.profile_snapshot list -> unit
