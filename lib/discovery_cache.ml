(** Discovery_cache — cached wrapper over OAS [Llm_provider.Discovery].

    All probing logic lives in OAS. This module adds:
    - TTL-based caching (30s default)
    - Convenience queries (any_local_healthy, idle/busy counts)
    - Eio capability injection (set_env at server init)

    No dependency on Llm_cascade.

    @since 2.130.0 — renamed from Llm_discovery_cache *)

(* ── Eio capability refs (set once at server init) ───────── *)

let sw_ref : Eio.Switch.t option ref = ref None
let net_ref : [`Generic | `Unix] Eio.Net.ty Eio.Resource.t option ref = ref None

let set_env ~sw ~(net : [`Generic | `Unix] Eio.Net.ty Eio.Resource.t) =
  sw_ref := Some sw;
  net_ref := Some net

(* ── Cache state ─────────────────────────────────────────── *)

type endpoint_info = Llm_provider.Discovery.endpoint_status

let cached_endpoints : endpoint_info list ref = ref []
let cache_updated_at : float ref = ref 0.0
let cache_ttl = 30.0

let refresh_cache () =
  match !sw_ref, !net_ref with
  | Some sw, Some net ->
    let endpoints = Llm_provider.Discovery.endpoints_from_env () in
    let results = Llm_provider.Discovery.discover ~sw ~net ~endpoints in
    cached_endpoints := results;
    cache_updated_at := Time_compat.now ()
  | _ ->
    (* Eio env not yet injected — return empty. Server init calls set_env. *)
    ()

let get_cached_or_refresh () =
  let now = Time_compat.now () in
  if now -. !cache_updated_at > cache_ttl || !cached_endpoints = [] then
    refresh_cache ();
  !cached_endpoints

let cache_age_seconds () =
  Time_compat.now () -. !cache_updated_at

(* ── Convenience queries ─────────────────────────────────── *)

let any_local_healthy () =
  let endpoints = get_cached_or_refresh () in
  List.exists (fun (e : endpoint_info) -> e.healthy) endpoints

let idle_slot_count () =
  let endpoints = get_cached_or_refresh () in
  List.fold_left (fun acc (e : endpoint_info) ->
    match e.slots with
    | Some s -> acc + s.idle
    | None -> acc) 0 endpoints

let busy_slot_count () =
  let endpoints = get_cached_or_refresh () in
  List.fold_left (fun acc (e : endpoint_info) ->
    match e.slots with
    | Some s -> acc + s.busy
    | None -> acc) 0 endpoints

(* ── JSON (delegates to OAS) ─────────────────────────────── *)

let endpoint_to_json = Llm_provider.Discovery.endpoint_status_to_json
