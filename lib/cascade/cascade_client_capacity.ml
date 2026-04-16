(** See cascade_client_capacity.mli for documentation. *)

type entry = {
  max_concurrent : int;
  active : int Atomic.t;
}

let registry : (string, entry) Hashtbl.t = Hashtbl.create 4
let registry_mu = Mutex.create ()

let clamp_max n = if n < 1 then 1 else n

let register ~url ~max_concurrent =
  let max_concurrent = clamp_max max_concurrent in
  Mutex.protect registry_mu (fun () ->
      match Hashtbl.find_opt registry url with
      | None ->
        let e = { max_concurrent; active = Atomic.make 0 } in
        Hashtbl.replace registry url e
      | Some existing ->
        if existing.max_concurrent <> max_concurrent then
          (* Keep the active counter; replace only the cap. *)
          Hashtbl.replace registry url
            { max_concurrent; active = existing.active })

let registered_urls () =
  Mutex.protect registry_mu (fun () ->
      Hashtbl.fold (fun url _ acc -> url :: acc) registry [])

let snapshot () =
  Mutex.protect registry_mu (fun () ->
      Hashtbl.fold
        (fun url e acc ->
           let active = Atomic.get e.active in
           let info : Cascade_throttle.capacity_info =
             { total = e.max_concurrent;
               process_active = active;
               process_available = max 0 (e.max_concurrent - active);
               process_queue_length = 0;
               source = Llm_provider.Provider_throttle.Fallback;
             }
           in
           (url, info) :: acc)
        registry [])

let unregister_all () =
  Mutex.protect registry_mu (fun () -> Hashtbl.clear registry)

let lookup url =
  Mutex.protect registry_mu (fun () -> Hashtbl.find_opt registry url)

let is_registered url = lookup url <> None

let capacity url =
  match lookup url with
  | None -> None
  | Some e ->
    let active = Atomic.get e.active in
    let available = max 0 (e.max_concurrent - active) in
    Some
      {
        Cascade_throttle.total = e.max_concurrent;
        process_active = active;
        process_available = available;
        process_queue_length = 0;
        source = Llm_provider.Provider_throttle.Fallback;
      }

type release = unit -> unit

let try_acquire url =
  match lookup url with
  | None -> None
  | Some e ->
    (* Optimistic CAS on the atomic counter.  Loop to retry when
       another fiber bumps the count between read and CAS. *)
    let rec attempt () =
      let current = Atomic.get e.active in
      if current >= e.max_concurrent then begin
        (* Slot full: record for observability before returning. *)
        Cascade_client_capacity_history.record {
          ts = Unix.gettimeofday ();
          key = url;
          kind = Rejected_full;
          active_after = current;
        };
        None
      end
      else if Atomic.compare_and_set e.active current (current + 1) then (
        Cascade_client_capacity_history.record {
          ts = Unix.gettimeofday ();
          key = url;
          kind = Acquired;
          active_after = current + 1;
        };
        let released = Atomic.make false in
        let release () =
          if not (Atomic.exchange released true) then begin
            (* Decrement once, ensure no underflow from double release
               even though the flag guards us. *)
            let prev = Atomic.fetch_and_add e.active (-1) in
            Cascade_client_capacity_history.record {
              ts = Unix.gettimeofday ();
              key = url;
              kind = Released;
              active_after = prev - 1;
            }
          end
        in
        Some release)
      else attempt ()
    in
    attempt ()

(* ── Env parsing ────────────────────────────────────────────────── *)

let int_of_env ?(default = 0) name =
  match Sys.getenv_opt name with
  | None | Some "" -> default
  | Some s -> (try int_of_string (String.trim s) with _ -> default)

let ollama_default_max () =
  max 1 (int_of_env ~default:1 "MASC_OLLAMA_MAX_CONCURRENT")

let cli_default_max () =
  max 1 (int_of_env ~default:1 "MASC_CLI_MAX_CONCURRENT")

(* Parse "url=max,url=max,..." from MASC_CLIENT_CAPACITY. *)
let parse_capacity_env s =
  String.split_on_char ',' s
  |> List.filter_map (fun item ->
         let item = String.trim item in
         if item = "" then None
         else
           match String.index_opt item '=' with
           | None -> None
           | Some idx ->
             let url = String.trim (String.sub item 0 idx) in
             let rest =
               String.trim
                 (String.sub item (idx + 1) (String.length item - idx - 1))
             in
             match int_of_string_opt rest with
             | Some n when n >= 1 && url <> "" -> Some (url, n)
             | _ -> None)

let () =
  match Sys.getenv_opt "MASC_CLIENT_CAPACITY" with
  | None | Some "" -> ()
  | Some s ->
    List.iter
      (fun (url, max_concurrent) -> register ~url ~max_concurrent)
      (parse_capacity_env s)

(* ── Heuristic auto-registration for ollama-like URLs ───────────── *)

(* Fast substring check without pulling in [Re]. *)
let contains_substring haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 || nlen > hlen then false
  else
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

let looks_like_ollama url =
  (* Port 11434 is Ollama's well-known default port.  The string
     match is intentionally permissive (works for http://, https://,
     127.0.0.1, localhost, bare host:port). *)
  contains_substring url ":11434"

let cli_sentinel_prefix = "cli:"

let looks_like_cli_sentinel url =
  let plen = String.length cli_sentinel_prefix in
  String.length url > plen && String.sub url 0 plen = cli_sentinel_prefix

let auto_register_for_candidates ~base_urls =
  let max_concurrent = ollama_default_max () in
  List.iter
    (fun url ->
       if looks_like_ollama url && not (is_registered url) then
         register ~url ~max_concurrent)
    base_urls

let auto_register_ollama_with_override ~base_urls ~max_concurrent =
  List.iter
    (fun url ->
       if looks_like_ollama url && not (is_registered url) then
         register ~url ~max_concurrent)
    base_urls

let auto_register_cli_for_candidates ~capacity_keys =
  let max_concurrent = cli_default_max () in
  List.iter
    (fun key ->
       if looks_like_cli_sentinel key && not (is_registered key) then
         register ~url:key ~max_concurrent)
    capacity_keys

let auto_register_cli_with_override ~capacity_keys ~max_concurrent =
  List.iter
    (fun key ->
       if looks_like_cli_sentinel key && not (is_registered key) then
         register ~url:key ~max_concurrent)
    capacity_keys
