(** Operator snapshot cache — stale-while-revalidate with background refresh.

    The dashboard calls [Operator_control_snapshot.snapshot_json] frequently,
    but the snapshot can take tens of seconds to build (per-keeper audit/trust
    file I/O dominates).  A plain TTL cache causes blocking or timeouts when
    compute cost exceeds the TTL.  This cache instead serves the previous
    snapshot immediately while a background fiber recomputes, so the dashboard
    never waits on the hot path.

    Design points:
    - Atomic StringMap with CAS loops, mirroring [Dashboard_cache].
    - Per-key singleflight: only one fiber computes a given key at a time.
    - Bounded poll-retry waiters (not [Condition.await] inside a mutex) so
      cancellation never gets stuck.
    - Cancellation restores a stale fallback when one exists.
    - Process switch from [Eio_context.get_switch_opt] runs background refreshes.

    The public interface stays compatible with the previous module:
    [invalidate_snapshot_cache] clears all entries. *)

module SMap = Set_util.StringMap

let now () = Time_compat.now ()

(** Fresh value window plus stale-while-revalidate window. *)
type entry = {
  value : Yojson.Safe.t;
  expires_at : float;
  stale_until : float;
}

(** In-flight computation. [stale] holds the previous value that may be served
    while the new value is being computed. *)
type slot =
  | Ready of entry
  | Computing of {
      token : int;
      started_at : float;
      stale : Yojson.Safe.t option;
    }

let table : slot SMap.t Atomic.t = Atomic.make SMap.empty
let token_counter = Atomic.make 0
let next_token () = Atomic.fetch_and_add token_counter 1

(* Maximum snapshot cache entries. Each entry holds a full JSON snapshot tree
   which can be several MB. *)
let max_entries = 16

(** Evict one expired or oldest entry when the table reaches the cap.
    Called inside an atomic-update critical section. *)
let maybe_evict map =
  if SMap.cardinal map > max_entries
  then (
    let now_ts = now () in
    let victim = ref None in
    SMap.iter
      (fun key slot ->
         match slot, !victim with
         | Ready entry, None when entry.stale_until <= now_ts -> victim := Some key
         | Ready entry, None when entry.expires_at <= now_ts -> victim := Some key
         | Ready _, None -> ()
         | Ready _, Some _ -> ()
         | Computing _, _ -> ())
      map;
    match !victim with
    | Some key -> SMap.remove key map
    | None ->
      (* If everything is fresh or computing, evict the entry closest to
         expiry. Never evict an in-flight computation: duplicate expensive
         snapshot work is worse than a temporary memory growth. *)
      let oldest_cached = ref None in
      SMap.iter
        (fun key slot ->
           match slot with
           | Ready { expires_at; _ } ->
             (match !oldest_cached with
              | None -> oldest_cached := Some (key, expires_at)
              | Some (_, e) when expires_at < e -> oldest_cached := Some (key, expires_at)
              | Some _ -> ())
           | Computing _ -> ())
        map;
      (match !oldest_cached with
       | Some (key, _) -> SMap.remove key map
       | None -> map))
  else map
;;

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let result, new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then result else atomic_update atomic f
;;

let metric_label = [ ("cache", "operator") ]

let inc_stale_served () =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_operator_snapshot_stale_served_total
    ~labels:metric_label
    ()
;;

(** Cancellation-safe sleep. If the current fiber is cancelled while sleeping,
    the exception propagates. *)
let sleep_sec sec = Time_compat.sleep sec

(** Poll interval for waiters parked on an in-flight computation. *)
let wait_poll_interval_sec = 0.25

(** Safety ceiling for how long a waiter will poll a Computing slot before
    evicting it and recomputing. Derived from the configured TTL so the bound
    scales with the freshness window rather than a fixed magic number. *)
let max_wait_sec () =
  Float.max 60.0 (Env_config_runtime_services.Operator.cache_ttl_sec *. 10.0)
;;

(** Background recompute fiber. Runs [compute] and writes back the result if
    the slot still belongs to [token]. On failure, restores the stale fallback
    with an extended stale window so callers are not blocked. *)
let do_bg_compute ~key ~token ~ttl ~stale_value compute =
  let stale_grace = ttl *. Env_config_runtime_services.Operator.cache_stale_grace_factor in
  let run () =
    try
      let value = compute () in
      let ts = now () in
      atomic_update table (fun map ->
          match SMap.find_opt key map with
          | Some (Computing { token = t; _ }) when t = token ->
            let entry =
              { value
              ; expires_at = ts +. ttl
              ; stale_until = ts +. ttl +. stale_grace
              }
            in
            ((), SMap.add key (Ready entry) map)
          | _ ->
            Log.Dashboard.debug
              "operator_snapshot_cache: bg-revalidate discarded for %s (slot replaced)"
              key;
            ((), map))
    with
    | Eio.Cancel.Cancelled _ as e ->
      (* Restore stale fallback so the next read does not block. *)
      let ts = now () in
      atomic_update table (fun map ->
          match SMap.find_opt key map with
          | Some (Computing { token = t; _ }) when t = token ->
            ((),
             SMap.add
               key
               (Ready
                  { value = stale_value
                  ; expires_at = ts
                  ; stale_until = ts +. (stale_grace *. 2.0)
                  })
               map)
          | _ -> ((), map));
      raise e
    | exn ->
      Log.Dashboard.warn
        "operator_snapshot_cache: bg-revalidate failed (%s): %s"
        key
        (Printexc.to_string exn);
      let ts = now () in
      atomic_update table (fun map ->
          match SMap.find_opt key map with
          | Some (Computing { token = t; _ }) when t = token ->
            ((),
             SMap.add
               key
               (Ready
                  { value = stale_value
                  ; expires_at = ts
                  ; stale_until = ts +. (stale_grace *. 2.0)
                  })
               map)
          | _ -> ((), map))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
    (try Eio.Fiber.fork ~sw run with
     | Invalid_argument _ -> run ()
     | Eio.Cancel.Cancelled _ -> ())
  | None ->
    Log.Dashboard.warn
      "operator_snapshot_cache: no switch for background revalidation, computing inline (%s)"
      key;
    run ()
;;

(** Run [compute] inline and write the result into the slot owned by [token].
    Returns the computed value on success. On exception, restores [stale] if
    present and re-raises; otherwise removes the slot and re-raises. *)
let run_compute_inline ~key ~token ~ttl ~stale compute =
  let stale_grace = ttl *. Env_config_runtime_services.Operator.cache_stale_grace_factor in
  try
    let value = compute () in
    let ts = now () in
    atomic_update table (fun map ->
        match SMap.find_opt key map with
        | Some (Computing { token = t; _ }) when t = token ->
          ((),
           SMap.add
             key
             (Ready { value; expires_at = ts +. ttl; stale_until = ts +. ttl +. stale_grace })
             map)
        | _ ->
          Log.Dashboard.debug
            "operator_snapshot_cache: inline compute result discarded for %s (slot replaced)"
            key;
          ((), map));
    value
  with
  | Eio.Cancel.Cancelled _ as e ->
    let ts = now () in
    (match stale with
     | Some stale_value ->
       atomic_update table (fun map ->
           match SMap.find_opt key map with
           | Some (Computing { token = t; _ }) when t = token ->
             ((),
              SMap.add
                key
                (Ready { value = stale_value; expires_at = ts; stale_until = ts +. stale_grace })
                map)
           | _ -> ((), map))
     | None ->
       atomic_update table (fun map ->
           match SMap.find_opt key map with
           | Some (Computing { token = t; _ }) when t = token -> ((), SMap.remove key map)
           | _ -> ((), map)));
    raise e
  | exn ->
    (match stale with
     | Some stale_value ->
       let ts = now () in
       atomic_update table (fun map ->
           match SMap.find_opt key map with
           | Some (Computing { token = t; _ }) when t = token ->
             ((),
              SMap.add
                key
                (Ready { value = stale_value; expires_at = ts; stale_until = ts +. stale_grace })
                map)
           | _ -> ((), map))
     | None ->
       atomic_update table (fun map ->
           match SMap.find_opt key map with
           | Some (Computing { token = t; _ }) when t = token -> ((), SMap.remove key map)
           | _ -> ((), map)));
    raise exn
;;

(** Main lookup. Returns the snapshot for [key], using the cache semantics
    described in the module header. *)
let get_or_compute key ~ttl compute =
  if not (Eio_guard.is_ready ())
  then compute ()
  else (
    let bg_enabled = Env_config_runtime_services.Operator.cache_background_revalidate in
    let rec try_get ~waited ~watching_token =
      let action =
        atomic_update table (fun map ->
            let map = maybe_evict map in
            match SMap.find_opt key map with
            | Some (Ready entry) when entry.expires_at > now () -> (`Hit entry.value, map)
            | Some (Ready entry) when entry.stale_until > now () ->
              let token = next_token () in
              ( `Stale (entry.value, token)
              , SMap.add key (Computing { token; started_at = now (); stale = Some entry.value }) map )
            | Some (Computing { stale = Some stale_value; _ }) -> (`Hit stale_value, map)
            | Some (Computing { token; started_at; stale = None }) ->
              let waited =
                match watching_token with
                | Some t when t <> token -> 0.0
                | _ -> waited
              in
              let elapsed = now () -. started_at in
              let ceiling = max_wait_sec () in
              if elapsed > ceiling || waited > ceiling
              then (
                Log.Dashboard.warn
                  "operator_snapshot_cache: evicting stuck Computing slot for %s (%.1fs elapsed)"
                  key
                  elapsed;
                (`Retry, SMap.remove key map))
              else (`Wait token, map)
            | Some (Ready entry) ->
              let token = next_token () in
              ( `Compute (token, Some entry.value)
              , SMap.add key (Computing { token; started_at = now (); stale = Some entry.value }) map )
            | None ->
              let token = next_token () in
              (`Compute (token, None), SMap.add key (Computing { token; started_at = now (); stale = None }) map))
      in
      match action with
      | `Hit v -> v
      | `Stale (stale_value, token) ->
        if bg_enabled
        then do_bg_compute ~key ~token ~ttl ~stale_value compute
        else
          (* Background revalidation disabled: treat stale as a miss and recompute
             inline, but keep the stale fallback in case of failure. *)
          run_compute_inline ~key ~token ~ttl ~stale:(Some stale_value) compute
            |> ignore;
        inc_stale_served ();
        stale_value
      | `Wait token ->
        sleep_sec wait_poll_interval_sec;
        try_get ~waited:(waited +. wait_poll_interval_sec) ~watching_token:(Some token)
      | `Compute (token, stale) -> run_compute_inline ~key ~token ~ttl ~stale compute
      | `Retry -> try_get ~waited:0.0 ~watching_token:None
    in
    try_get ~waited:0.0 ~watching_token:None)
;;

let invalidate_snapshot_cache () =
  if Eio_guard.is_ready ()
  then
    (* Any in-flight compute that finishes after this will see its token gone
       and discard its writeback. Waiters will see the slot removed and start
       a fresh compute. *)
    Atomic.set table SMap.empty
  else Atomic.set table SMap.empty
;;

let peek key =
  let ts = now () in
  let map = Atomic.get table in
  match SMap.find_opt key map with
  | Some (Ready entry) when entry.stale_until > ts -> Some entry.value
  | Some (Computing { stale = Some stale_value; _ }) -> Some stale_value
  | _ -> None
;;

type slot_kind = Fresh | Stale | Expired | Computing_slot

let slot_kind_to_string = function
  | Fresh -> "fresh"
  | Stale -> "stale"
  | Expired -> "expired"
  | Computing_slot -> "computing"
;;

let slot_kind ~now_ts = function
  | Ready e ->
    if now_ts <= e.expires_at then Fresh
    else if now_ts <= e.stale_until then Stale
    else Expired
  | Computing _ -> Computing_slot
;;

let stats () =
  let map = Atomic.get table in
  let now_ts = now () in
  let fresh = ref 0 in
  let stale = ref 0 in
  let expired = ref 0 in
  let computing = ref 0 in
  SMap.iter
    (fun _key slot ->
       match slot_kind ~now_ts slot with
       | Fresh -> incr fresh
       | Stale -> incr stale
       | Expired -> incr expired
       | Computing_slot -> incr computing)
    map;
  `Assoc
    [ ("entries", `Int (SMap.cardinal map))
    ; ("fresh", `Int !fresh)
    ; ("stale", `Int !stale)
    ; ("expired", `Int !expired)
    ; ("computing", `Int !computing)
    ; ("max_entries", `Int max_entries)
    ]
;;
