(** Discovery_cache — cached wrapper over AGENT_CORE Provider Discovery.

    All probing logic lives in AGENT_CORE. This module adds:
    - TTL-based caching (30s default)
    - Convenience queries (any_local_healthy, idle/busy counts)
    - Eio capability injection (set_env at server init)

    @since 2.130.0 *)

(* ── Eio capability snapshot (set at server init) ────────── *)

type environment = {
  switch : Eio.Switch.t;
  net : [`Generic | `Unix] Eio.Net.ty Eio.Resource.t;
}

(* ── Cache snapshot ──────────────────────────────────────── *)

type endpoint_info = Llm_provider.Discovery.endpoint_status

type cache_snapshot = {
  endpoints : endpoint_info list;
  updated_at : float;
}

type runtime_state = {
  environment : environment option;
  cache : cache_snapshot;
}

let empty_cache = { endpoints = []; updated_at = 0.0 }
let state = Atomic.make { environment = None; cache = empty_cache }
let cache_ttl = 30.0

let set_env ~sw ~(net : [`Generic | `Unix] Eio.Net.ty Eio.Resource.t) =
  Atomic_util.update state (fun _ ->
    { environment = Some { switch = sw; net }; cache = empty_cache })

(* Probe every configured endpoint outside the atomic publication
   step. The result is installed only if the exact state observed before
   the probe is still current. Environment replacement or another completed
   refresh makes the result obsolete. *)
let refresh_cache () =
  let observed = Atomic.get state in
  match observed.environment with
  | Some { switch; net } ->
    let endpoints =
      Llm_provider.Provider_registry.active_llama_endpoints ()
    in
    let results =
      Llm_provider.Discovery.discover ~sw:switch ~net ~endpoints
    in
    let next =
      {
        observed with
        cache = { endpoints = results; updated_at = Time_compat.now () };
      }
    in
    ignore (Atomic.compare_and_set state observed next : bool)
  | None -> ()

let get_cached_or_refresh () =
  let snapshot = (Atomic.get state).cache in
  let stale_by_ttl = Time_compat.now () -. snapshot.updated_at > cache_ttl in
  let need_refresh =
    stale_by_ttl || snapshot.endpoints = []
  in
  if need_refresh then refresh_cache ();
  (Atomic.get state).cache.endpoints

let cache_age_seconds () =
  let snapshot = (Atomic.get state).cache in
  Time_compat.now () -. snapshot.updated_at

let model_of_status (status : endpoint_info) =
  if not status.healthy then None
  else
    match status.models with
    | model :: _ -> String_util.trim_nonempty model.id
    | [] ->
      (match status.props with
       | Some props -> String_util.trim_nonempty props.model
       | None -> None)

let first_ollama_model_id_for_url url =
  let cached = get_cached_or_refresh () in
  match List.find_map (fun (status : endpoint_info) ->
    if status.url = url then model_of_status status else None) cached with
  | Some _ as model -> model
  | None ->
    (match (Atomic.get state).environment with
     | None -> None
     | Some { switch; net } ->
       let declared =
         Llm_provider.Discovery.endpoint
           ~protocol:Llm_provider.Discovery.Ollama_native
           ~capabilities:Llm_provider.Capabilities.ollama_capabilities url
       in
       (match Llm_provider.Discovery.discover ~sw:switch ~net ~endpoints:[ declared ] with
        | [ status ] -> model_of_status status
        | _ -> None))
