(** See cascade_openai_probe.mli for documentation. *)

(* ── Explicit URL registry ──────────────────────────────────── *)
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

(* ── Cache ──────────────────────────────────────────────────── *)

type cache_entry =
  { capacity : Cascade_throttle.capacity_info
  ; recorded_at : float
  }

let cache_ttl_s = 5.0

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

let parse_response json =
  match json with
  | `Assoc _ ->
    (match Json_util.assoc_member_opt "object" json with
     | `String "list" ->
       (match Json_util.assoc_member_opt "data" json with
        | `List items when List.length items > 0 ->
          Some
            { Cascade_throttle.total = 1
            ; process_active = 0
            ; process_available = 1
            ; process_queue_length = 0
            ; source = Llm_provider.Provider_throttle.Discovered
            }
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

(* ── HTTP probe ─────────────────────────────────────────────── *)

let probe_endpoint_of base_url =
  let stripped =
    if String.ends_with ~suffix:"/" base_url
    then String.sub base_url 0 (String.length base_url - 1)
    else base_url
  in
  stripped ^ "/v1/models"
;;

let probe_timeout_default_s = 2.0

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
  let endpoint = probe_endpoint_of url in
  match
    Masc_http_client.get_sync
      ?clock
      ~timeout_sec:timeout_s
      ~url:endpoint
      ~headers:[ "accept", "application/json" ]
      ()
  with
  | Error message ->
    Log.Cascade.debug
      "[cascade-openai-probe] probe transport failure at %s: %s"
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
       (match parse_response json with
        | None ->
          Log.Cascade.debug
            "[cascade-openai-probe] dropping probe response from %s: \
             unexpected shape; body_preview=%S"
            endpoint body_preview;
          None
        | Some cap ->
          store_capacity ~url ~capacity:cap ~now;
          Some cap)
     | Error (`Json_parse_error msg) ->
       Log.Cascade.debug
         "[cascade-openai-probe] dropping probe response from %s: \
          malformed JSON (%s); body_preview=%S"
         endpoint msg body_preview;
       None
     | Error (`Other exn) ->
       Log.Cascade.debug
         "[cascade-openai-probe] dropping probe response from %s: %s; \
          body_preview=%S"
         endpoint (Printexc.to_string exn) body_preview;
       None)
  | Ok (status, _body) ->
    Log.Cascade.debug
      "[cascade-openai-probe] probe non-200 at %s: status=%d"
      endpoint status;
    None
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
         | Some _ -> ()
         | None ->
           let _ = try_probe ~sw ~net ~timeout_s url in
           ()))
    urls
;;

(* ── Probe adapter ───────────────────────────────────────────── *)

module Openai_probe = struct
  let can_probe ~url =
    String.length url > 0
  ;;

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
