type source =
  [ `Proactive
  | `On_demand
  | `Stale_fallback
  ]

type entry =
  { generated_at : float
  ; json : Yojson.Safe.t
  ; source : source
  }

type cache_key =
  | Execution of
      { actor : string option
      ; fixture : string option
      ; full : bool
      ; force : bool
      }
  | Runtime_probe of { force : bool }
  | Runtime_trace of
      { keeper_name : string
      ; trace_id : string option
      ; turn_id : int option
      ; limit : int
      }
  | Fleet_composite
  | Keeper_composite of { keeper_name : string }

(* Hard cap to prevent unbounded memory growth under unusual load patterns.
   The cache stores small JSON snapshots; 1 000 entries is generous for the
   dashboard surfaces currently cached. When the cap is hit the whole cache is
   cleared rather than implementing LRU — the proactive/on-demand compute loop
   will refill the hot entries quickly. *)
let max_entries = 1_000

type t =
  { mutable table : (cache_key, entry) Hashtbl.t
  ; mutex : Mutex.t
  }

let create () = { table = Hashtbl.create 64; mutex = Mutex.create () }

let global_cache = lazy (create ())
let global () = Lazy.force global_cache

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f
;;

let cache_key_to_string = function
  | Execution _ -> "execution"
  | Runtime_probe { force } -> Printf.sprintf "runtime-probe(force=%b)" force
  | Runtime_trace { keeper_name; limit; _ } ->
    Printf.sprintf "runtime-trace(%s,limit=%d)" keeper_name limit
  | Fleet_composite -> "fleet-composite"
  | Keeper_composite { keeper_name } ->
    Printf.sprintf "keeper-composite(%s)" keeper_name
;;

let get t key =
  let result = with_lock t (fun () -> Hashtbl.find_opt t.table key) in
  Log.Dashboard.debug
    "read_model_cache %s: %s"
    (cache_key_to_string key)
    (match result with Some _ -> "hit" | None -> "miss");
  result
;;

let get_fresh t key ~ttl_s =
  let now = Time_compat.now () in
  match get t key with
  | None -> None
  | Some entry when now -. entry.generated_at <= ttl_s -> Some entry
  | Some _ ->
    Log.Dashboard.debug "read_model_cache %s: stale" (cache_key_to_string key);
    None
;;

let get_or_stale t key ~stale_threshold_s =
  let now = Time_compat.now () in
  match get t key with
  | None -> None
  | Some entry when now -. entry.generated_at <= stale_threshold_s ->
    Some { entry with source = `Stale_fallback }
  | Some _ -> None
;;

let put t key entry =
  with_lock t (fun () ->
    if Hashtbl.length t.table >= max_entries
    then (
      Log.Dashboard.warn
        "read_model_cache reached max_entries (%d); clearing"
        max_entries;
      Hashtbl.clear t.table);
    Hashtbl.replace t.table key entry);
  Log.Dashboard.debug "read_model_cache %s: put" (cache_key_to_string key)
;;

let get_or_compute t key ~ttl_s ~compute =
  match get_fresh t key ~ttl_s with
  | Some entry -> entry.json
  | None ->
    Log.Dashboard.debug "read_model_cache %s: compute" (cache_key_to_string key);
    let json = compute () in
    put t key { generated_at = Time_compat.now (); json; source = `On_demand };
    json
;;

let invalidate t key =
  with_lock t (fun () -> Hashtbl.remove t.table key);
  Log.Dashboard.debug "read_model_cache %s: invalidate" (cache_key_to_string key)
;;

let invalidate_by_keeper t keeper_name =
  with_lock t (fun () ->
    let to_remove = ref [] in
    Hashtbl.iter
      (fun key _ ->
         match key with
         | Runtime_trace { keeper_name = kn; _ } when String.equal kn keeper_name ->
           to_remove := key :: !to_remove
         | Keeper_composite { keeper_name = kn } when String.equal kn keeper_name ->
           to_remove := key :: !to_remove
         | _ -> ())
      t.table;
    List.iter (Hashtbl.remove t.table) !to_remove);
  Log.Dashboard.debug "read_model_cache: invalidate_by_keeper(%s)" keeper_name
;;

let clear t =
  with_lock t (fun () -> Hashtbl.clear t.table);
  Log.Dashboard.debug "read_model_cache: clear"
