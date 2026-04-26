(** Discovery_cache — cached wrapper over OAS Provider Discovery.

    All probing logic lives in OAS. This module adds:
    - TTL-based caching (30s default)
    - Convenience queries (any_local_healthy, idle/busy counts)
    - Eio capability injection (set_env at server init)

    @since 2.130.0 *)

(* ── Eio capability refs (set once at server init) ───────── *)

let sw_ref : Eio.Switch.t option Atomic.t = Atomic.make None

let net_ref : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option Atomic.t =
  Atomic.make None
;;

let base_path_ref : string option Atomic.t = Atomic.make None

let set_env ~sw ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t) =
  Atomic.set sw_ref (Some sw);
  Atomic.set net_ref (Some net)
;;

let set_base_path path = Atomic.set base_path_ref (Some path)

(* ── Cache state (Eio.Mutex-protected) ───────────────────── *)

type endpoint_info = Llm_provider.Discovery.endpoint_status

let cache_mu = Eio.Mutex.create ()
let cached_endpoints : endpoint_info list ref = ref []
let cache_updated_at : float Atomic.t = Atomic.make 0.0
let cache_ttl = 30.0

(* Probe every configured endpoint and install the result under the
   mutex.  The probe itself ([Llm_provider.Discovery.discover])
   makes HTTP requests — potentially several seconds of network
   I/O — so it must NOT be executed while holding [cache_mu].

   The prior version was named [refresh_cache_unlocked] and was
   called from inside [get_cached_or_refresh]'s [Eio.Mutex.use_rw]
   block, which meant every dashboard / local-runtime consumer
   waited on the mutex for the full probe duration.  That is the
   same drift class as the prompt_registry [_unlocked] variants
   fixed in PR #6663 — the in-tree API was refactored to keep I/O
   out of the critical section, but a sibling helper with a
   misleading "_unlocked" name was left with the old pattern.

   This version splits the work: the HTTP probe runs with no lock
   held, then the result is installed under the mutex.  Two
   concurrent refreshers may both probe; that is wasteful but
   correct.  In practice the 30 s TTL narrows the window. *)
let refresh_cache () =
  match Atomic.get sw_ref, Atomic.get net_ref with
  | Some sw, Some net ->
    let endpoints = Llm_provider.Provider_registry.active_llama_endpoints () in
    (* HTTP probes — executed OUTSIDE [cache_mu]. *)
    let results = Llm_provider.Discovery.discover ~sw ~net ~endpoints in
    (* Install the fresh result under the mutex — no yields inside
       this critical section. *)
    Eio.Mutex.use_rw ~protect:true cache_mu (fun () ->
      cached_endpoints := results;
      Atomic.set cache_updated_at (Time_compat.now ()));
    (* Persist probe snapshot for time-series history — file I/O,
       also kept outside the mutex. *)
    (match Atomic.get base_path_ref with
     | Some bp -> Discovery_history.record_probe ~base_path:bp results
     | None -> ())
  | _ -> ()
;;

let get_cached_or_refresh () =
  (* Cheap staleness check: [cache_updated_at] is [Atomic] so the
     TTL comparison needs no lock.  Only when the cached list is
     still empty do we take the mutex to decide. *)
  let stale_by_ttl = Time_compat.now () -. Atomic.get cache_updated_at > cache_ttl in
  let need_refresh =
    stale_by_ttl
    || Eio.Mutex.use_rw ~protect:true cache_mu (fun () -> !cached_endpoints = [])
  in
  if need_refresh then refresh_cache ();
  Eio.Mutex.use_rw ~protect:true cache_mu (fun () -> !cached_endpoints)
;;

let cache_age_seconds () = Time_compat.now () -. Atomic.get cache_updated_at

(* ── Convenience queries ─────────────────────────────────── *)

let any_local_healthy () =
  let endpoints = get_cached_or_refresh () in
  List.exists (fun (e : endpoint_info) -> e.healthy) endpoints
;;

let idle_slot_count () =
  let endpoints = get_cached_or_refresh () in
  List.fold_left
    (fun acc (e : endpoint_info) ->
       match e.slots with
       | Some s -> acc + s.idle
       | None -> acc)
    0
    endpoints
;;

let busy_slot_count () =
  let endpoints = get_cached_or_refresh () in
  List.fold_left
    (fun acc (e : endpoint_info) ->
       match e.slots with
       | Some s -> acc + s.busy
       | None -> acc)
    0
    endpoints
;;

(* ── JSON (delegates to OAS) ─────────────────────────────── *)

let endpoint_to_json = Llm_provider.Discovery.endpoint_status_to_json
let summary_to_json = Llm_provider.Discovery.summary_to_json
