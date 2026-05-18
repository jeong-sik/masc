(** File-stamp caches for {!Memory_oas_bridge}. *)

module SMap = Map.Make (String)

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then ()
  else atomic_update atomic f

type file_stamp = float * int

let file_stamp_opt path =
  try
    let stats = Unix.stat path in
    Some (stats.Unix.st_mtime, stats.Unix.st_size)
  with
  | Unix.Unix_error _ -> None
  | Sys_error _ -> None

type episode_file_cache =
  { stamp : file_stamp option
  ; episodes : Institution_eio.episode list
  ; ids : unit SMap.t
  }

let episode_file_cache_tbl : episode_file_cache SMap.t Atomic.t =
  Atomic.make SMap.empty

let episode_ids_of episodes =
  List.fold_left
    (fun acc (episode : Institution_eio.episode) -> SMap.add episode.id () acc)
    SMap.empty
    episodes

(* Keep at most this many episodes in the in-memory cache.
   Callers that need fewer use cached_recent_episodes ~limit. *)
let episode_cache_limit = 500

(* Pure cache construction: stat + JSONL read + build a fresh
   [episode_file_cache]. Touches no shared state, so safe to run
   with no lock held. *)
let build_episode_cache_from_disk path =
  let stamp = file_stamp_opt path in
  let episodes =
    Institution_eio.load_recent_episodes_jsonl ~limit:episode_cache_limit
  in
  { stamp; episodes; ids = episode_ids_of episodes }

(* Cache-aware episode loader.

   Previously held [episode_cache_mu] across
   [Institution_eio.load_recent_episodes_jsonl] on every cache miss,
   meaning all concurrent [persisted_episode_ids]
   / [cached_recent_episodes] callers serialised on a single JSONL
   read of up to [episode_cache_limit = 500] records. Same drift
   class as the [Prompt_registry] / [Discovery_cache] siblings fixed
   in PRs #6663 / #6668 - an [_unlocked] helper was called from
   inside the caller's [with_mutex], re-introducing the
   I/O-under-lock anti-pattern.

   Split into:
   1. Stamp check under the mutex (pure [Hashtbl.find_opt] +
      [Unix.stat]).
   2. Hot path returns the cached record if the stamp still matches.
   3. On miss, release the lock, build the cache from disk outside
      the lock, install under a fresh short mutex section.

   Concurrent misses may both run the JSONL read; that is wasteful
   but correct (the last writer wins on [Hashtbl.replace]). In
   practice the stamp check short-circuits the vast majority of
   calls. *)
let load_all_episodes_cached () =
  let path = Institution_eio.episodes_jsonl_path () in
  let current_stamp = file_stamp_opt path in
  let cached_opt =
    match SMap.find_opt path (Atomic.get episode_file_cache_tbl) with
    | Some cache when cache.stamp = current_stamp -> Some cache
    | _ -> None
  in
  match cached_opt with
  | Some cache -> cache
  | None ->
    let fresh = build_episode_cache_from_disk path in
    atomic_update episode_file_cache_tbl (fun map -> SMap.add path fresh map);
    fresh

let rec drop_list n = function
  | [] -> []
  | remaining when n <= 0 -> remaining
  | _ :: rest -> drop_list (n - 1) rest

let cached_recent_episodes ~limit =
  let cache = load_all_episodes_cached () in
  let total = List.length cache.episodes in
  if total <= limit then cache.episodes else drop_list (total - limit) cache.episodes

let persisted_episode_ids () =
  (load_all_episodes_cached ()).ids

(* Record an episode that was just appended to the JSONL file.

   Previously called [load_all_episodes_cached_unlocked] while
   holding [episode_cache_mu], which meant a cache-miss during
   flush would block on the same under-mutex JSONL read the main
   fix addresses above. Instead, look the cache up in place: if
   it exists, mutate in place (fast path - no I/O); if it's
   missing, skip - the next [load_all_episodes_cached] call will
   populate a fresh cache from disk including the newly-appended
   episode.

   The [stamp] update keeps the cache in sync with the file's new
   mtime so subsequent loaders do not trigger a reload purely
   because [note_episode_flush] just wrote to the file. *)
let note_episode_flush (episode : Institution_eio.episode) =
  let path = Institution_eio.episodes_jsonl_path () in
  atomic_update episode_file_cache_tbl (fun map ->
    match SMap.find_opt path map with
    | None -> map
    | Some cache ->
      if not (SMap.mem episode.id cache.ids)
      then (
        let episodes = cache.episodes @ [ episode ] in
        let total = List.length episodes in
        let ids_ref = ref (SMap.add episode.id () cache.ids) in
        let episodes =
          if total > episode_cache_limit
          then (
            let drop_n = total - episode_cache_limit in
            let rec drop_with_evict n = function
              | [] -> []
              | remaining when n <= 0 -> remaining
              | (ep : Institution_eio.episode) :: rest ->
                ids_ref := SMap.remove ep.id !ids_ref;
                drop_with_evict (n - 1) rest
            in
            drop_with_evict drop_n episodes)
          else episodes
        in
        let new_cache =
          { stamp = file_stamp_opt path; episodes; ids = !ids_ref }
        in
        SMap.add path new_cache map)
      else
        let new_cache = { cache with stamp = file_stamp_opt path } in
        SMap.add path new_cache map)

type procedure_file_cache =
  { stamp : file_stamp option
  ; procedures : Procedural_memory.procedure list
  }

let procedure_file_cache_tbl : procedure_file_cache SMap.t Atomic.t =
  Atomic.make SMap.empty

let load_procedures_cached ~(agent_name : string) =
  let path = Procedural_memory.procedures_path ~agent_name in
  let stamp = file_stamp_opt path in
  match SMap.find_opt path (Atomic.get procedure_file_cache_tbl) with
  | Some cache when cache.stamp = stamp -> cache.procedures
  | _ ->
    let procedures = Procedural_memory.load_procedures ~agent_name in
    atomic_update procedure_file_cache_tbl (fun map ->
      SMap.add path { stamp; procedures } map);
    procedures

let store_procedures_cache
      ~(agent_name : string)
      (procedures : Procedural_memory.procedure list)
  =
  let path = Procedural_memory.procedures_path ~agent_name in
  let stamp = file_stamp_opt path in
  atomic_update procedure_file_cache_tbl (fun map ->
    SMap.add path { stamp; procedures } map)

let top_procedures_cached ~(agent_name : string) ~(limit : int) =
  load_procedures_cached ~agent_name
  |> List.filter Procedural_memory.is_crystallized
  |> List.sort (fun (a : Procedural_memory.procedure)
                     (b : Procedural_memory.procedure) ->
    Float.compare b.confidence a.confidence)
  |> List.filteri (fun i _ -> i < limit)
