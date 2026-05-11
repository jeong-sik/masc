(** See cascade_http_probe.mli for documentation. *)

(* ── URL classification ─────────────────────────────────────── *)

(* Re-export the shared heuristic from [Masc_network_defaults].  Keeping
   the symbol here preserves this module's public [.mli] surface while
   eliminating the substring literal duplicated across cascade modules.

   Substring-scan classification is unreliable: a vLLM server on :11434
   matches; an ollama on a non-default port does not. The probe's
   [Http_probe] adapter therefore consults an explicit registry instead
   (see [registered_urls] below); [is_ollama_url] survives only as a
   transitional helper for legacy callers in other modules. *)
let is_ollama_url = Masc_network_defaults.is_ollama_url

(* ── Explicit URL registry (replaces substring scan inside this module) ───
   Probes only fire against URLs that callers have explicitly registered,
   eliminating the [:11434] substring heuristic's false positives. The
   default ollama URL is registered at module load to preserve
   out-of-the-box behaviour for the canonical local deployment. *)
let registered_urls : (string, unit) Hashtbl.t = Hashtbl.create 4
let registry_mutex = Eio.Mutex.create ()

let register_url ~url =
  Eio.Mutex.use_rw ~protect:false registry_mutex (fun () ->
    Hashtbl.replace registered_urls url ())
;;

let is_registered ~url =
  Eio.Mutex.use_ro registry_mutex (fun () -> Hashtbl.mem registered_urls url)
;;

let registered_count () =
  Eio.Mutex.use_ro registry_mutex (fun () -> Hashtbl.length registered_urls)
;;

let registry_clear () =
  Eio.Mutex.use_rw ~protect:false registry_mutex (fun () ->
    Hashtbl.clear registered_urls)
;;

let () = register_url ~url:Masc_network_defaults.ollama_default_url

(* ── Cache ──────────────────────────────────────────────────── *)

type cache_entry =
  { capacity : Cascade_throttle.capacity_info
  ; recorded_at : float
  }

let cache_ttl_s = 2.0
(* Short TTL: ollama state changes whenever any client (this MASC,
   another keeper, dashboard) runs inference.  Treating a 30s-old
   cache hit as authoritative is worse than missing the
   optimisation. *)

let cache : (string, cache_entry) Hashtbl.t = Hashtbl.create 8
let cache_mutex = Eio.Mutex.create ()
let now_default () = Unix.gettimeofday ()

let cache_clear () =
  Eio.Mutex.use_rw ~protect:false cache_mutex (fun () -> Hashtbl.clear cache)
;;

let cache_size () = Eio.Mutex.use_ro cache_mutex (fun () -> Hashtbl.length cache)

let cached_capacity ?now url =
  let now =
    match now with
    | Some n -> n
    | None -> now_default ()
  in
  Eio.Mutex.use_ro cache_mutex (fun () ->
    match Hashtbl.find_opt cache url with
    | Some entry when now -. entry.recorded_at <= cache_ttl_s -> Some entry.capacity
    | _ -> None)
;;

let store_capacity ~url ~capacity ~now =
  Eio.Mutex.use_rw ~protect:false cache_mutex (fun () ->
    Hashtbl.replace cache url { capacity; recorded_at = now })
;;

(* ── JSON parser ────────────────────────────────────────────── *)

(* Ollama [/api/ps] response shape (from
   https://github.com/ollama/ollama/blob/main/docs/api.md):
   {
     "models": [
       { "name": "qwen3-coder:30b", "size_vram": ..., ... },
       ...
     ]
   }

   We only care about [models].length: each loaded model occupies
   one "active" slot under the assumption that
   [OLLAMA_NUM_PARALLEL=1] (the ollama default).  Users running
   parallel mode can override [total] via the optional argument
   so [process_available] is still meaningful. *)
let parse_response ?(total = 1) ?now json =
  let _ = now in
  let open Yojson.Safe.Util in
  match json with
  | `Assoc _ ->
    (match member "models" json with
     | `List items ->
       let process_active = List.length items in
       let process_available = max 0 (total - process_active) in
       Some
         { Cascade_throttle.total
         ; process_active
         ; process_available
         ; process_queue_length = 0
         ; source = Llm_provider.Provider_throttle.Discovered
         }
     | _ -> None)
  | _ -> None
;;

(* ── HTTP probe ─────────────────────────────────────────────── *)

(* Build [<base_url>/api/ps], normalising the trailing slash. *)
let probe_endpoint_of base_url =
  let stripped =
    if String.ends_with ~suffix:"/" base_url
    then String.sub base_url 0 (String.length base_url - 1)
    else base_url
  in
  stripped ^ Masc_network_defaults.ollama_api_ps_path
;;

(* Probe HTTP timeout.

   0.5s suits a fast box serving small models; a box loading a large
   model shares the same lock as [/api/ps] and can briefly exceed
   this. Caller may override via the optional [?timeout_s] argument
   when a longer ceiling is needed. *)
let probe_timeout_default_s = 0.5

let try_probe ~sw ~net ?clock ?timeout_s ?now url =
  let timeout_s =
    match timeout_s with
    | Some v -> v
    | None -> probe_timeout_default_s
  in
  let _ = sw in
  let now =
    match now with
    | Some n -> n
    | None -> now_default ()
  in
  let endpoint = probe_endpoint_of url in
  match
    Masc_http_client.get_sync
      ?clock
      ~timeout_sec:timeout_s
      ~net
      ~url:endpoint
      ~headers:[ "accept", "application/json" ]
      ()
  with
  | Error _ -> None
  | Ok (status, body) when status = 200 ->
    (match Yojson.Safe.from_string body with
     | exception _ -> None
     | json ->
       (match parse_response ~now json with
        | None -> None
        | Some cap ->
          store_capacity ~url ~capacity:cap ~now;
          Some cap))
  | Ok _ -> None
;;

let refresh_many ~sw ~net ?timeout_s urls =
  let timeout_s =
    match timeout_s with
    | Some v -> v
    | None -> probe_timeout_default_s
  in
  List.iter
    (fun url ->
       if is_registered ~url
       then (
         match cached_capacity url with
         | Some _ -> () (* still fresh, skip *)
         | None ->
           let _ = try_probe ~sw ~net ~timeout_s url in
           ()))
    urls
;;

(* ── Probe adapter ───────────────────────────────────────────── *)

(* Wraps this module's functions as a first-class [Probe] for
   {!Cascade_capacity_probe}.  The module structurally satisfies
   [Cascade_capacity_probe.Probe] without an explicit annotation,
   avoiding a circular dependency between the two compilation units. *)
module Http_probe = struct
  let can_probe ~url = is_registered ~url

  let probe ~sw ~net ~url ?timeout_s () =
    match timeout_s with
    | None -> try_probe ~sw ~net url
    | Some v -> try_probe ~sw ~net ~timeout_s:v url
  ;;

  let cached ~url ?now () =
    match now with
    | None -> cached_capacity url
    | Some v -> cached_capacity ~now:v url
  ;;

  let refresh_many ~sw ~net ~urls ?timeout_s () =
    match timeout_s with
    | None -> refresh_many ~sw ~net urls
    | Some v -> refresh_many ~sw ~net ~timeout_s:v urls
  ;;
end
