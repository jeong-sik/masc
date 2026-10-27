(** Discovery_cache — cached wrapper over AGENT_CORE Provider Discovery.

    All probing logic lives in AGENT_CORE. This module adds:
    - TTL-based caching (30s default)
    - Convenience queries (any_local_healthy, idle/busy counts)
    - Eio capability injection (set_env at server init)

    @since 2.130.0 *)

(* ── Eio capability snapshot (set at server init) ────────── *)

type environment = {
  switch : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  net : [`Generic | `Unix] Eio.Net.ty Eio.Resource.t;
}

(* ── Cache snapshot ──────────────────────────────────────── *)

type endpoint_info = Llm_provider.Discovery.endpoint_status

type request_scope =
  | Public
  | Header_fingerprint of string

type model_key = {
  url : string;
  protocol : Llm_provider.Discovery.endpoint_protocol;
  scope : request_scope;
}

type model_observation = {
  key : model_key;
  model_id : string;
  observed_at : float;
}

type cache_snapshot = {
  endpoints : endpoint_info list;
  models : model_observation list;
  updated_at : float;
}

type runtime_state = {
  environment : environment option;
  cache : cache_snapshot;
}

let empty_cache = { endpoints = []; models = []; updated_at = 0.0 }
let state = Atomic.make { environment = None; cache = empty_cache }
let cache_ttl = 30.0

let set_env ~sw ~clock ~(net : [`Generic | `Unix] Eio.Net.ty Eio.Resource.t) =
  Atomic_util.update state (fun _ ->
    { environment = Some { switch = sw; clock; net }; cache = empty_cache })

let model_of_status (status : endpoint_info) =
  if not status.healthy then None
  else
    match status.models with
    | model :: _ -> String_util.trim_nonempty model.id
    | [] ->
      (match status.props with
       | Some props -> String_util.trim_nonempty props.model
       | None -> None)

let fresh_observation now (observation : model_observation) =
  now -. observation.observed_at <= cache_ttl

let public_observations now results =
  List.filter_map (fun (status : endpoint_info) ->
    Option.map (fun model_id ->
      let key = { url = status.url; protocol = status.protocol; scope = Public } in
      { key; model_id; observed_at = now }) (model_of_status status)) results

let scope_of_headers = function
  | [] -> Public
  | headers ->
    let wire =
      `List (List.map (fun (name, value) -> `List [ `String name; `String value ]) headers)
      |> Yojson.Safe.to_string
    in
    Header_fingerprint Agent_core_sha256.(to_hex (digest_string wire))

let same_model_key left right =
  String.equal left.url right.url
  && left.protocol = right.protocol
  && left.scope = right.scope

let publish_model_observation observed key model_id =
  let observed_at = Time_compat.now () in
  let models =
    { key; model_id; observed_at }
    :: List.filter (fun observation ->
      not (same_model_key observation.key key) && fresh_observation observed_at observation)
      observed.cache.models
  in
  let next = { observed with cache = { observed.cache with models } } in
  ignore (Atomic.compare_and_set state observed next : bool)

(* Probe every configured endpoint outside the atomic publication
   step. The result is installed only if the exact state observed before
   the probe is still current. Environment replacement or another completed
   refresh makes the result obsolete. *)
let refresh_cache () =
  let observed = Atomic.get state in
  match observed.environment with
  | Some { switch; clock; net } ->
    let endpoints =
      Llm_provider.Provider_registry.active_llama_endpoints ()
    in
    let results =
      Llm_provider.Discovery.discover ~headers:[] ~clock ~sw:switch ~net ~endpoints ()
    in
    let now = Time_compat.now () in
    let retained =
      List.filter (fun observation ->
        fresh_observation now observation
        && (match observation.key.scope with
          | Header_fingerprint _ -> true
          | Public ->
            not (List.exists (fun (status : endpoint_info) ->
              String.equal status.url observation.key.url
              && status.protocol = observation.key.protocol) results)))
        observed.cache.models
    in
    let cache = {
      endpoints = results;
      models = public_observations now results @ retained;
      updated_at = now;
    } in
    let next = { observed with cache } in
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

let first_ollama_model_id_for_url ~timeout_s ?(headers=[]) url =
  let snapshot = Atomic.get state in
  let scope = scope_of_headers headers in
  let key = { url; protocol = Llm_provider.Discovery.Ollama_native; scope } in
  let now = Time_compat.now () in
  let cached =
    List.find_map (fun observation ->
      if same_model_key observation.key key && fresh_observation now observation
      then Some observation.model_id else None) snapshot.cache.models
  in
  match cached with
  | Some _ as model -> model
  | None ->
    (match snapshot.environment with
     | None -> None
     | Some { switch; clock; net } ->
       let declared =
         Llm_provider.Discovery.endpoint
           ~protocol:Llm_provider.Discovery.Ollama_native
           ~capabilities:Llm_provider.Capabilities.ollama_capabilities url
       in
       (match Llm_provider.Discovery.discover ~headers ~clock ~timeout_s ~sw:switch ~net ~endpoints:[ declared ] () with
        | [ status ] ->
          (match model_of_status status with
           | Some model_id ->
             publish_model_observation snapshot key model_id;
             Some model_id
           | None -> None)
        | _ -> None))
