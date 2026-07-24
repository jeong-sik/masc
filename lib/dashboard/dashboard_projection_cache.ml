(** Shared actor-scoped projection caching for dashboard surfaces.

    Execution and mission both derive top-level summaries from the same
    operator snapshot. Reuse short-lived actor-scoped cache entries so warm
    refresh loops and repeated navigation do not recompute identical reads. *)

let cache_partition_segment (_config : Workspace_utils.config) = "default"

let actor_cache_key (config : Workspace_utils.config) prefix actor_name =
  Printf.sprintf "%s:%s:%s:%s" prefix config.base_path
    (cache_partition_segment config) actor_name

let normalize_actor_name = function
  | Some value ->
      let trimmed = String.trim value in
      if trimmed <> "" then trimmed else "dashboard"
  | None -> "dashboard"

let snapshot_cache_ttl_s = 5.0
let digest_cache_ttl_s = 5.0
let snapshot_publication_mu = Stdlib.Mutex.create ()
let snapshot_invalidation_generation_ref = Atomic.make 0
let snapshot_generation_observer : (int -> unit) option Atomic.t = Atomic.make None

let register_snapshot_generation_observer observer =
  Atomic.set snapshot_generation_observer (Some observer)
;;

let with_snapshot_publication_generation f =
  Stdlib.Mutex.protect snapshot_publication_mu (fun () ->
    f (Atomic.get snapshot_invalidation_generation_ref))
;;

let get_or_compute_snapshot_json ~config ~actor compute =
  let actor_name = normalize_actor_name actor in
  Dashboard_cache.get_or_compute
    (actor_cache_key config "snapshot" actor_name)
    ~ttl:snapshot_cache_ttl_s (fun () -> compute actor_name)

let invalidate_snapshot_json ~config =
  let generation =
    Stdlib.Mutex.protect snapshot_publication_mu (fun () ->
      Dashboard_cache.invalidate_prefix (actor_cache_key config "snapshot" "");
      Dashboard_cache.invalidate_prefix "operator_snapshot:";
      Atomic.fetch_and_add snapshot_invalidation_generation_ref 1 + 1)
  in
  (* The callback intentionally runs after the generation lock is released.
     It must use the publication owner's generation/terminal CAS rather than
     fabricating an envelope from a later cache read: callbacks may arrive out
     of order under concurrent invalidations. *)
  match Atomic.get snapshot_generation_observer with
  | None -> ()
  | Some observer ->
    (try observer generation with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Dashboard.warn
         "snapshot generation observer failed generation=%d: %s"
         generation
         (Printexc.to_string exn))
;;

let get_or_compute_digest_json ~config ~actor compute =
  let actor_name = normalize_actor_name actor in
  Dashboard_cache.get_or_compute
    (actor_cache_key config "digest" actor_name)
    ~ttl:digest_cache_ttl_s (fun () -> compute actor_name)

type operator_snapshot_fn = {
  snapshot : 'a.
    ?actor:string ->
    ?view:string ->
    ?include_messages:bool ->
    ?include_keepers:bool ->
    ?include_summary_fields:bool ->
    ?lightweight_summary:bool ->
    'a Tool_operator.context ->
    Yojson.Safe.t;
}

type operator_digest_fn = {
  digest : 'a.
    ?actor:string ->
    ?target_type:string ->
    ?target_id:string ->
    ?include_workers:bool ->
    'a Tool_operator.context ->
    (Yojson.Safe.t, string) result;
}

let operator_snapshot_json_ref : operator_snapshot_fn ref =
  ref { snapshot = (fun ?actor:_ ?view:_ ?include_messages:_ ?include_keepers:_ ?include_summary_fields:_ ?lightweight_summary:_ _ctx ->
    `Null) }

let register_operator_snapshot_json fn =
  operator_snapshot_json_ref := fn

let operator_digest_json_ref : operator_digest_fn ref =
  ref { digest = (fun ?actor:_ ?target_type:_ ?target_id:_ ?include_workers:_ _ctx ->
    Ok `Null) }

let register_operator_digest_json fn =
  operator_digest_json_ref := fn

let operator_snapshot_json ?actor ?view ?include_messages ?include_keepers ?include_summary_fields ?lightweight_summary ctx =
  (!operator_snapshot_json_ref).snapshot ?actor ?view ?include_messages ?include_keepers ?include_summary_fields ?lightweight_summary ctx

let operator_digest_json ?actor ?target_type ?target_id ?include_workers ctx =
  (!operator_digest_json_ref).digest ?actor ?target_type ?target_id ?include_workers ctx
