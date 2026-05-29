(** See cascade_http_probe.mli for documentation. *)

(* ── Probe mode ─────────────────────────────────────────────── *)

type probe_mode =
  | Ollama
  | Generic of { endpoint_path : string }

(* ── Explicit URL registry ──────────────────────────────────── *)

let registered_urls : (string, probe_mode) Hashtbl.t = Hashtbl.create 4
let registry_mutex = Eio.Mutex.create ()

let register_url ?(mode = Ollama) ~url () =
  Eio.Mutex.use_rw ~protect:false registry_mutex (fun () ->
    Hashtbl.replace registered_urls url mode)
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

let () = register_url ~url:Masc_network_defaults.ollama_default_url ()

(* ── Cache ──────────────────────────────────────────────────── *)

type cache_entry =
  { capacity : Cascade_throttle.capacity_info
  ; recorded_at : float
  }

let cache_ttl_s = 2.0

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

(* ── JSON parsers ───────────────────────────────────────────── *)

let parse_ollama_response ?(total = 1) json =
  let open Yojson.Safe.Util in
  match json with
  | `Assoc _ ->
    (match member "models" json with
     | `List items ->
       let process_available = max 0 (total - List.length items) in
       Some
         { Cascade_throttle.process_available
         ; source = Llm_provider.Provider_throttle.Discovered
         }
     | _ -> None)
  | _ -> None
;;

let parse_generic_response _json = Some 1

(* ── HTTP probe ─────────────────────────────────────────────── *)

let probe_endpoint_of ~endpoint_path base_url =
  let stripped =
    if String.ends_with ~suffix:"/" base_url
    then String.sub base_url 0 (String.length base_url - 1)
    else base_url
  in
  stripped ^ endpoint_path
;;

let probe_timeout_default_s = 0.5

let try_probe ~sw ~net:_ ?clock ?timeout_s ?now url =
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
  let mode =
    Eio.Mutex.use_ro registry_mutex (fun () ->
      Hashtbl.find_opt registered_urls url)
  in
  let mode =
    match mode with
    | Some m -> m
    | None -> Generic { endpoint_path = "/v1/models" }
  in
  let endpoint_path =
    match mode with
    | Ollama -> Masc_network_defaults.ollama_api_ps_path
    | Generic { endpoint_path } -> endpoint_path
  in
  let endpoint = probe_endpoint_of ~endpoint_path url in
  match
    Masc_http_client.get_sync
      ?clock
      ~timeout_sec:timeout_s
      ~url:endpoint
      ~headers:[ "accept", "application/json" ]
      ()
  with
  | Error message ->
    Log.Cascade.warn
      "[cascade-http-probe] probe transport failure at %s: %s"
      endpoint message;
    None
  | Ok (status, body) when status = 200 ->
    let body_preview =
      String.sub body 0 (min 200 (String.length body))
    in
    let parsed =
      try Ok (Yojson.Safe.from_string body) with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | Yojson.Json_error msg -> Error (`Json_parse_error msg)
      | exn -> Error (`Other exn)
    in
    (match parsed with
     | Ok json ->
       let available_opt =
         match mode with
         | Ollama -> parse_ollama_response json
         | Generic _ ->
           (match parse_generic_response json with
            | Some n ->
              Some
                { Cascade_throttle.process_available = n
                ; source = Llm_provider.Provider_throttle.Discovered
                }
            | None -> None)
       in
       (match available_opt with
        | None -> None
        | Some cap ->
          store_capacity ~url ~capacity:cap ~now;
          Some cap)
     | Error (`Json_parse_error msg) ->
       Log.Cascade.warn
         "[cascade-http-probe] dropping probe response from %s: \
          malformed JSON (%s); body_preview=%S"
         endpoint msg body_preview;
       Prometheus.inc_counter
         Keeper_metrics.(to_string CascadeHttpProbeJsonParseFailures)
         ~labels:
           [ ("error_kind", "yojson_parse_error")
           ; ("probe_kind", "http")
           ]
         ();
       None
     | Error (`Other exn) ->
       Log.Cascade.warn
         "[cascade-http-probe] dropping probe response from %s: %s; \
          body_preview=%S"
         endpoint (Printexc.to_string exn) body_preview;
       Prometheus.inc_counter
         Keeper_metrics.(to_string CascadeHttpProbeJsonParseFailures)
         ~labels:
           [ ("error_kind", "other"); ("probe_kind", "http") ]
         ();
       None)
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
