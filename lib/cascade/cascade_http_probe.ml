(** See cascade_ollama_probe.mli for documentation. *)

(* ── URL classification ─────────────────────────────────────── *)

(* Re-export the shared heuristic from [Masc_network_defaults].  Keeping
   the symbol here preserves this module's public [.mli] surface while
   eliminating the substring literal duplicated across cascade modules. *)
let is_ollama_url = Masc_network_defaults.is_ollama_url

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

(* Operator-tunable default for the probe timeout.

   Was a literal [0.5] embedded twice (in [try_probe] and
   [refresh_many]).  Operators reported that 0.5s is fine for ollama
   serving small models on a fast box but is tight when the box is
   loading a big model (the [/api/ps] handler shares the same lock
   as model load) — in those cases the probe times out, the cache
   stays cold, and the cascade backs off to a non-local provider
   even though ollama is healthy and only briefly busy.

   Resolution order (process env > literal default):
   - [MASC_OLLAMA_PROBE_TIMEOUT_SEC]  (float)

   Range [0.05, 30.0]; out-of-range or unparseable values fall back
   to the literal default with a one-shot WARN.

   Read at every call site so operator changes via runtime tooling
   take effect without a process restart.  The cost is one
   [Sys.getenv_opt] per probe attempt, which is negligible compared
   to the HTTP round-trip the probe makes. *)
let probe_timeout_default_s = 0.5
let probe_timeout_env_var = "MASC_OLLAMA_PROBE_TIMEOUT_SEC"
let probe_timeout_warned = Atomic.make false

let probe_timeout_resolved () =
  match Sys.getenv_opt probe_timeout_env_var with
  | None -> probe_timeout_default_s
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = ""
    then probe_timeout_default_s
    else (
      match float_of_string_opt trimmed with
      | Some v when v >= 0.05 && v <= 30.0 -> v
      | Some _ | None ->
        if not (Atomic.exchange probe_timeout_warned true)
        then
          Log.Misc.warn
            "Ignoring %s=%S (expected float in [0.05, 30.0]); using default %.2fs."
            probe_timeout_env_var
            raw
            probe_timeout_default_s;
        probe_timeout_default_s)
;;

let try_probe ~sw ~net ?clock ?timeout_s ?now url =
  let timeout_s =
    match timeout_s with
    | Some v -> v
    | None -> probe_timeout_resolved ()
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
    | None -> probe_timeout_resolved ()
  in
  List.iter
    (fun url ->
       if is_ollama_url url
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
  let can_probe ~url = is_ollama_url url

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
