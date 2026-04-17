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

type env_int_value =
  | Missing
  | Blank
  | Parsed of int
  | Invalid of string

let read_env_int name =
  match Sys.getenv_opt name with
  | None -> Missing
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then Blank
    else
      match Safe_ops.int_of_string_safe trimmed with
      | Some value -> Parsed value
      | None -> Invalid raw

let int_of_env ?(default = 0) name =
  match read_env_int name with
  | Missing
  | Blank -> default
  | Parsed value -> value
  | Invalid raw ->
    Log.Misc.warn "Invalid int for %s=%S, using default %d" name raw default;
    default

let ollama_default_max () =
  max 1 (int_of_env ~default:1 "MASC_OLLAMA_MAX_CONCURRENT")

let cli_default_max () =
  max 1 (int_of_env ~default:1 "MASC_CLI_MAX_CONCURRENT")

(* Parse "url=max,url=max,..." from MASC_CLIENT_CAPACITY. *)
type capacity_entry_error =
  | Missing_separator of string
  | Empty_url of string
  | Invalid_capacity of string
  | Non_positive_capacity of int

let capacity_entry_error_message = function
  | Missing_separator raw ->
    Printf.sprintf "missing '=' in %S" raw
  | Empty_url raw ->
    Printf.sprintf "empty url in %S" raw
  | Invalid_capacity raw ->
    Printf.sprintf "invalid capacity %S" raw
  | Non_positive_capacity value ->
    Printf.sprintf "capacity must be >= 1 (got %d)" value

let parse_capacity_entry raw_item =
  let item = String.trim raw_item in
  if item = "" then Ok None
  else
    match String.index_opt item '=' with
    | None -> Error (Missing_separator item)
    | Some idx ->
      let url = String.trim (String.sub item 0 idx) in
      let raw_capacity =
        String.trim
          (String.sub item (idx + 1) (String.length item - idx - 1))
      in
      if url = "" then Error (Empty_url item)
      else
        match Safe_ops.int_of_string_safe raw_capacity with
        | Some n when n >= 1 -> Ok (Some (url, n))
        | Some n -> Error (Non_positive_capacity n)
        | None -> Error (Invalid_capacity raw_capacity)

let parse_capacity_env s =
  String.split_on_char ',' s
  |> List.filter_map (fun item ->
         match parse_capacity_entry item with
         | Ok (Some entry) -> Some entry
         | Ok None -> None
         | Error err ->
           Log.Misc.warn "Ignoring invalid MASC_CLIENT_CAPACITY entry: %s"
             (capacity_entry_error_message err);
           None)

let () =
  match Sys.getenv_opt "MASC_CLIENT_CAPACITY" with
  | None | Some "" -> ()
  | Some s ->
    List.iter
      (fun (url, max_concurrent) -> register ~url ~max_concurrent)
      (parse_capacity_env s)

(* ── Heuristic auto-registration for ollama-like URLs ───────────── *)

let looks_like_ollama = Masc_network_defaults.is_ollama_url

let looks_like_cli_sentinel = Masc_network_defaults.is_cli_sentinel_url

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
