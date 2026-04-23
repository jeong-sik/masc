(** Shared actor-scoped projection caching for dashboard surfaces.

    Execution and mission both derive top-level summaries from the same
    operator snapshot. Reuse short-lived actor-scoped cache entries so warm
    refresh loops and repeated navigation do not recompute identical reads. *)

let cache_partition_segment (_config : Coord_utils.config) = "default"

let actor_cache_key (config : Coord_utils.config) prefix actor_name =
  Printf.sprintf "%s:%s:%s:%s" prefix config.base_path
    (cache_partition_segment config) actor_name

let normalize_actor_name = function
  | Some value when String.trim value <> "" -> String.trim value
  | _ -> "dashboard"

let get_or_compute_snapshot_json ~config ~actor compute =
  let actor_name = normalize_actor_name actor in
  Dashboard_cache.get_or_compute
    (actor_cache_key config "snapshot" actor_name)
    ~ttl:3.0 (fun () -> compute actor_name)

let invalidate_snapshot_json ~config =
  Dashboard_cache.invalidate_prefix (actor_cache_key config "snapshot" "")

let get_or_compute_digest_json ~config ~actor compute =
  let actor_name = normalize_actor_name actor in
  Dashboard_cache.get_or_compute
    (actor_cache_key config "digest" actor_name)
    ~ttl:5.0 (fun () -> compute actor_name)
