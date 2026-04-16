(** See cascade_ollama_probe.mli for documentation. *)

(* ── URL classification ─────────────────────────────────────── *)

(* Substring helper — duplicated from Cascade_client_capacity to
   avoid a hard dependency on a sibling module's private function.
   Both spellings agree on the [:11434] heuristic. *)
let contains_substring haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 || nl > hl then false
  else
    let rec loop i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else loop (i + 1)
    in
    loop 0

let is_ollama_url url = contains_substring url ":11434"

(* ── Cache ──────────────────────────────────────────────────── *)

type cache_entry = {
  capacity : Cascade_throttle.capacity_info;
  recorded_at : float;
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
  Eio.Mutex.use_rw ~protect:false cache_mutex (fun () ->
      Hashtbl.clear cache)

let cache_size () =
  Eio.Mutex.use_ro cache_mutex (fun () -> Hashtbl.length cache)

let cached_capacity ?now url =
  let now = match now with Some n -> n | None -> now_default () in
  Eio.Mutex.use_ro cache_mutex (fun () ->
      match Hashtbl.find_opt cache url with
      | Some entry when now -. entry.recorded_at <= cache_ttl_s ->
        Some entry.capacity
      | _ -> None)

let store_capacity ~url ~capacity ~now =
  Eio.Mutex.use_rw ~protect:false cache_mutex (fun () ->
      Hashtbl.replace cache url { capacity; recorded_at = now })

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
       Some {
         Cascade_throttle.total;
         process_active;
         process_available;
         process_queue_length = 0;
         source = Llm_provider.Provider_throttle.Discovered;
       }
     | _ -> None)
  | _ -> None

(* ── HTTP probe ─────────────────────────────────────────────── *)

(* Build [<base_url>/api/ps], normalising the trailing slash. *)
let probe_endpoint_of base_url =
  let stripped =
    if String.length base_url > 0
       && String.get base_url (String.length base_url - 1) = '/'
    then String.sub base_url 0 (String.length base_url - 1)
    else base_url
  in
  stripped ^ "/api/ps"

let try_probe ~sw ~net ?(timeout_s = 0.5) ?now url =
  let _ = sw in
  let _ = timeout_s in
  let now = match now with Some n -> n | None -> now_default () in
  let endpoint = probe_endpoint_of url in
  match
    Masc_http_client.get_sync
      ~net
      ~url:endpoint
      ~headers:[("accept", "application/json")]
      ()
  with
  | Error _ -> None
  | Ok (status, body) when status = 200 ->
    (match Yojson.Safe.from_string body with
     | exception _ -> None
     | json ->
       match parse_response ~now json with
       | None -> None
       | Some cap ->
         store_capacity ~url ~capacity:cap ~now;
         Some cap)
  | Ok _ -> None

let refresh_many ~sw ~net ?(timeout_s = 0.5) urls =
  List.iter
    (fun url ->
       if is_ollama_url url then
         match cached_capacity url with
         | Some _ -> ()                   (* still fresh, skip *)
         | None ->
           let _ = try_probe ~sw ~net ~timeout_s url in
           ())
    urls
