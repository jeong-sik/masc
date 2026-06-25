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
      }
  | Runtime_probe
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
   dashboard surfaces currently cached. When the cap is hit, evict only the
   oldest entry so a high-cardinality surface cannot flush every hot snapshot. *)
let max_entries = 1_000

module Key_map = Map.Make (struct
    type t = cache_key

    let compare = Stdlib.compare
  end)

type t =
  { table : entry Key_map.t Atomic.t }

let create () = { table = Atomic.make Key_map.empty }

let global_cache = create ()
let global () = global_cache

let rec atomic_update t f =
  let old_map = Atomic.get t.table in
  let result, new_map = f old_map in
  if Atomic.compare_and_set t.table old_map new_map
  then result
  else atomic_update t f
;;

let cache_key_to_string = function
  | Execution _ -> "execution"
  | Runtime_probe -> "runtime-probe"
  | Runtime_trace { keeper_name; limit; _ } ->
    Printf.sprintf "runtime-trace(%s,limit=%d)" keeper_name limit
  | Fleet_composite -> "fleet-composite"
  | Keeper_composite { keeper_name } ->
    Printf.sprintf "keeper-composite(%s)" keeper_name
;;

let get t key =
  let result = Key_map.find_opt key (Atomic.get t.table) in
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

let evict_oldest_if_full map =
  if Key_map.cardinal map < max_entries
  then map
  else (
    Log.Dashboard.warn
      "read_model_cache reached max_entries (%d); evicting oldest entry"
      max_entries;
    let oldest =
      Key_map.fold
        (fun key entry acc ->
           match acc with
           | None -> Some (key, entry.generated_at)
           | Some (_, oldest_ts) when entry.generated_at < oldest_ts ->
             Some (key, entry.generated_at)
           | Some _ as existing -> existing)
        map
        None
    in
    match oldest with
    | None -> map
    | Some (key, _) -> Key_map.remove key map)
;;

let put t key entry =
  atomic_update t (fun map ->
    let map = if Key_map.mem key map then map else evict_oldest_if_full map in
    ((), Key_map.add key entry map));
  Log.Dashboard.debug "read_model_cache %s: put" (cache_key_to_string key)
;;

let compute_and_store t key ~source ~compute =
  Log.Dashboard.debug "read_model_cache %s: compute" (cache_key_to_string key);
  let json = compute () in
  put t key { generated_at = Time_compat.now (); json; source };
  json
;;

let get_or_compute ?(force = false) t key ~ttl_s ~compute =
  if force
  then compute_and_store t key ~source:`On_demand ~compute
  else (
    match get_fresh t key ~ttl_s with
    | Some entry -> entry.json
    | None -> compute_and_store t key ~source:`On_demand ~compute)
;;

let invalidate t key =
  atomic_update t (fun map -> ((), Key_map.remove key map));
  Log.Dashboard.debug "read_model_cache %s: invalidate" (cache_key_to_string key)
;;

let invalidate_by_keeper t keeper_name =
  atomic_update t (fun map ->
    ( ()
    , Key_map.filter
        (fun key _ ->
           match key with
           | Runtime_trace { keeper_name = kn; _ } ->
             not (String.equal kn keeper_name)
           | Keeper_composite { keeper_name = kn } ->
             not (String.equal kn keeper_name)
           | _ -> true)
        map ));
  Log.Dashboard.debug "read_model_cache: invalidate_by_keeper(%s)" keeper_name
;;

let clear t =
  Atomic.set t.table Key_map.empty;
  Log.Dashboard.debug "read_model_cache: clear"
