module Cache_state = Server_dashboard_json_cache_state

type cached_prepared_entry =
  { cp_json : Yojson.Safe.t
  ; cp_state : Dashboard_cache_wire.state
  ; cp_last_error : string option
  ; cp_prepared : Server_cached_read_http.prepared_http
  }

type t =
  { states : (string, Cache_state.t) Hashtbl.t
  ; prepared : (string, cached_prepared_entry) Hashtbl.t
  }

let ttl_s = 60.0

(* Public query parameters contribute to keys. Keep each route's table bounded
   and evict the least recently refreshed entry before admitting a new key. *)
let max_entries = 128
let cache_mu = Stdlib.Mutex.create ()
let create () : t = { states = Hashtbl.create 8; prepared = Hashtbl.create 8 }

let cache_metadata ~state ~generated_at ?age_s ?error () =
  let optional_float name = function
    | None -> []
    | Some value -> [ name, `Float value ]
  in
  let optional_string name = function
    | None -> []
    | Some value -> [ name, `String value ]
  in
  `Assoc
    ([ "state", `String (Dashboard_cache_wire.to_string state)
     ; "generated_at", `Float generated_at
     ]
     @ optional_float "age_s" age_s
     @ optional_string "last_error" error)

let json_with_cache_metadata json metadata =
  match json with
  | `Assoc fields -> `Assoc (fields @ [ "cache", metadata ])
  | other -> `Assoc [ "payload", other; "cache", metadata ]

let cache_response ~now ~placeholder = function
  | Cache_state.Fresh { json; age_s } ->
      json_with_cache_metadata json
        (cache_metadata ~state:Dashboard_cache_wire.Cache_fresh
           ~generated_at:now ~age_s ())
  | Cache_state.Stale { json; age_s; last_error } ->
      json_with_cache_metadata json
        (cache_metadata ~state:Dashboard_cache_wire.Cache_stale_refreshing
           ~generated_at:now ~age_s ?error:last_error ())
  | Cache_state.Warming { last_error } ->
      json_with_cache_metadata placeholder
        (cache_metadata ~state:Dashboard_cache_wire.Cache_warming
           ~generated_at:now ?error:last_error ())

let store_prepared_locked cache key entry =
  if Hashtbl.length cache.prepared >= max_entries
     && not (Hashtbl.mem cache.prepared key)
  then Hashtbl.clear cache.prepared;
  Hashtbl.replace cache.prepared key entry

let read_view ~now:clock ~sync_first ~sw ~cache ~key ~pre_prepare ~compute =
  Eio.Switch.check sw;
  let now = clock () in
  let release owner =
    Stdlib.Mutex.protect cache_mu (fun () ->
        match Hashtbl.find_opt cache.states key with
        | None -> ()
        | Some entry ->
            Option.iter (Hashtbl.replace cache.states key) (Cache_state.cancel ~owner entry))
  in
  let run_compute_and_store ~background owner =
    (* Cleanup is synchronous: it cannot mask cancellation with an Eio effect.
       Successful settlement has already removed this exact owner. *)
    Fun.protect ~finally:(fun () -> release owner) (fun () ->
      let run () =
        Eio.Switch.check sw;
        let result, prepared_fresh =
          (* These computes transitively take process-shared Eio mutexes.
             Executor workers carry an Eio context; a bare systhread does not.
             Keep the executor's worker-cancellation/join protocol intact. *)
          try
            Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
              match compute () with
              | Ok json as res ->
                let prepared_fresh =
                  if pre_prepare then
                    let ts = clock () in
                    let full =
                      json_with_cache_metadata json
                        (cache_metadata ~state:Dashboard_cache_wire.Cache_fresh
                           ~generated_at:ts ~age_s:0.0 ())
                    in
                    Some (ts, Server_cached_read_http.prepare_json full)
                  else None
                in
                res, prepared_fresh
              | Error _ as err -> err, None)
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn), None
        in
        let refreshed_at =
          match prepared_fresh with
          | Some (ts, _) -> ts
          | None -> clock ()
        in
        Stdlib.Mutex.protect cache_mu (fun () ->
            match Hashtbl.find_opt cache.states key with
            | None -> ()
            | Some entry ->
                (match Cache_state.settle ~owner ~now:refreshed_at result entry with
                 | None -> ()
                 | Some settled ->
                   Hashtbl.replace cache.states key settled;
                   match result, prepared_fresh with
                   | Ok json, Some (_, cp_prepared) ->
                     store_prepared_locked cache key
                       { cp_json = json
                       ; cp_state = Dashboard_cache_wire.Cache_fresh
                       ; cp_last_error = None
                       ; cp_prepared
                       }
                   | Ok _, None | Error _, (Some _ | None) ->
                     Hashtbl.remove cache.prepared key));
        (match result with
         | Ok _ -> ()
         | Error message ->
             Log.Misc.warn "dashboard metrics cache refresh failed: %s" message);
        result, refreshed_at, Option.map snd prepared_fresh
      in
      if background then Pool_lane.with_background run else run ())
  in
  let view, owner =
    Stdlib.Mutex.protect cache_mu (fun () ->
        (* The supplied clock can cancel this scope after the initial check.
           Refuse admission before lookup, eviction or insertion mutates it. *)
        Eio.Switch.check sw;
        let entry =
          match Hashtbl.find_opt cache.states key with
          | Some entry -> entry
          | None ->
              Server_utils.evict_oldest_if_full ~max_entries:max_entries
                ~age_of:Cache_state.updated_at cache.states;
              let entry = Cache_state.empty in
              Hashtbl.add cache.states key entry;
              Hashtbl.remove cache.prepared key;
              entry
        in
        match Cache_state.admit ~now ~ttl_s:ttl_s entry with
        | Cache_state.Reuse view -> view, None
        | Cache_state.Refresh (view, plan) ->
            let entry, owner = Cache_state.start plan in
            Hashtbl.replace cache.states key entry;
            view, Some owner)
  in
  match owner with
  | None -> `View (now, view)
  | Some owner ->
      let was_cold = match view with
        | Cache_state.Warming _ -> true
        | Cache_state.Fresh _ | Cache_state.Stale _ -> false
      in
      if sync_first && was_cold then
        `Sync_result (run_compute_and_store ~background:false owner)
      else
        (* The switch retains fallback ownership cleanup until the child exits.
           Remove completed hooks so a serving switch retains only live work;
           exact-owner release makes worker and switch cleanup idempotent. *)
        (try
           Eio.Switch.check sw;
           let hook =
             Eio.Switch.on_release_cancellable sw (fun () -> release owner)
           in
           (try
              Eio.Fiber.fork ~sw (fun () ->
                  Fun.protect ~finally:(fun () -> Eio.Switch.remove_hook hook)
                    (fun () ->
                      ignore (run_compute_and_store ~background:true owner
                        : (Yojson.Safe.t, string) result * float * Server_cached_read_http.prepared_http option)));
              `View (now, view)
            with exn ->
              Eio.Switch.remove_hook hook;
              raise exn)
         with exn ->
           release owner;
           raise exn)

let read_result ~now:clock ~sync_first ~sw ~cache ~key ~placeholder ~compute =
  match read_view ~now:clock ~sync_first ~sw ~cache ~key ~pre_prepare:false ~compute with
  | `View (now, view) -> cache_response ~now ~placeholder view
  | `Sync_result (Ok json, refreshed_at, _) ->
      json_with_cache_metadata json
        (cache_metadata ~state:Dashboard_cache_wire.Cache_fresh
           ~generated_at:refreshed_at ())
  | `Sync_result (Error message, refreshed_at, _) ->
      cache_response ~now:refreshed_at ~placeholder
        (Cache_state.Warming { last_error = Some message })

let prepared_for_view ~cache ~key ~now ~placeholder view =
  match view with
  | Cache_state.Fresh { json; age_s } ->
    let hit =
      Stdlib.Mutex.protect cache_mu (fun () ->
        match Hashtbl.find_opt cache.prepared key with
        | Some cp
          when cp.cp_json == json
               && cp.cp_state = Dashboard_cache_wire.Cache_fresh ->
          Some cp.cp_prepared
        | Some _ | None -> None)
    in
    (match hit with
     | Some prepared -> prepared
     | None ->
       let full =
         json_with_cache_metadata json
           (cache_metadata ~state:Dashboard_cache_wire.Cache_fresh
              ~generated_at:(now -. age_s) ~age_s:0.0 ())
       in
       let cp_prepared = Server_cached_read_http.prepare_json full in
       Stdlib.Mutex.protect cache_mu (fun () ->
         store_prepared_locked cache key
           { cp_json = json
           ; cp_state = Dashboard_cache_wire.Cache_fresh
           ; cp_last_error = None
           ; cp_prepared
           });
       cp_prepared)
  | Cache_state.Stale { json; age_s; last_error } ->
    let hit =
      Stdlib.Mutex.protect cache_mu (fun () ->
        match Hashtbl.find_opt cache.prepared key with
        | Some cp
          when cp.cp_json == json
               && cp.cp_state = Dashboard_cache_wire.Cache_stale_refreshing
               && Option.equal String.equal cp.cp_last_error last_error ->
          Some cp.cp_prepared
        | Some _ | None -> None)
    in
    (match hit with
     | Some prepared -> prepared
     | None ->
       let full =
         json_with_cache_metadata json
           (cache_metadata ~state:Dashboard_cache_wire.Cache_stale_refreshing
              ~generated_at:now ~age_s ?error:last_error ())
       in
       let cp_prepared = Server_cached_read_http.prepare_json full in
       Stdlib.Mutex.protect cache_mu (fun () ->
         store_prepared_locked cache key
           { cp_json = json
           ; cp_state = Dashboard_cache_wire.Cache_stale_refreshing
           ; cp_last_error = last_error
           ; cp_prepared
           });
       cp_prepared)
  | Cache_state.Warming { last_error } ->
    let full =
      json_with_cache_metadata placeholder
        (cache_metadata ~state:Dashboard_cache_wire.Cache_warming
           ~generated_at:now ?error:last_error ())
    in
    Server_cached_read_http.prepare_json full

let read_prepared ~now:clock ~sync_first ~sw ~cache ~key ~placeholder ~compute =
  match read_view ~now:clock ~sync_first ~sw ~cache ~key ~pre_prepare:true ~compute with
  | `View (now, view) -> prepared_for_view ~cache ~key ~now ~placeholder view
  | `Sync_result (Ok _, _, Some prepared) -> prepared
  | `Sync_result (Ok json, refreshed_at, None) ->
      Server_cached_read_http.prepare_json
        (json_with_cache_metadata json
           (cache_metadata ~state:Dashboard_cache_wire.Cache_fresh
              ~generated_at:refreshed_at ~age_s:0.0 ()))
  | `Sync_result (Error message, refreshed_at, _) ->
      Server_cached_read_http.prepare_json
        (cache_response ~now:refreshed_at ~placeholder
           (Cache_state.Warming { last_error = Some message }))
