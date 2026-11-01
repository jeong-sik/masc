module Cache_state = Server_dashboard_json_cache_state

type t = (string, Cache_state.t) Hashtbl.t

let ttl_s = 60.0

(* Public query parameters contribute to keys. Keep each route's table bounded
   and evict the least recently refreshed entry before admitting a new key. *)
let max_entries = 128
let cache_mu = Stdlib.Mutex.create ()
let create () : t = Hashtbl.create 8

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

let read_result ~now:clock ~sync_first ~sw ~cache ~key ~placeholder ~compute =
  Eio.Switch.check sw;
  let now = clock () in
  let release owner =
    Stdlib.Mutex.protect cache_mu (fun () ->
        match Hashtbl.find_opt cache key with
        | None -> ()
        | Some entry ->
            Option.iter (Hashtbl.replace cache key) (Cache_state.cancel ~owner entry))
  in
  let run_compute_and_store ~background owner =
    (* Cleanup is synchronous: it cannot mask cancellation with an Eio effect.
       Successful settlement has already removed this exact owner. *)
    Fun.protect ~finally:(fun () -> release owner) (fun () ->
      let run () =
        Eio.Switch.check sw;
        let result =
          (* These computes transitively take process-shared Eio mutexes.
             Executor workers carry an Eio context; a bare systhread does not.
             Keep the executor's worker-cancellation/join protocol intact. *)
          try Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ compute with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        let refreshed_at = clock () in
        Stdlib.Mutex.protect cache_mu (fun () ->
            match Hashtbl.find_opt cache key with
            | None -> ()
            | Some entry ->
                Option.iter (Hashtbl.replace cache key)
                  (Cache_state.settle ~owner ~now:refreshed_at result entry));
        (match result with
         | Ok _ -> ()
         | Error message ->
             Log.Misc.warn "dashboard metrics cache refresh failed: %s" message);
        result, refreshed_at
      in
      if background then Pool_lane.with_background run else run ())
  in
  let view, owner =
    Stdlib.Mutex.protect cache_mu (fun () ->
        (* The supplied clock can cancel this scope after the initial check.
           Refuse admission before lookup, eviction or insertion mutates it. *)
        Eio.Switch.check sw;
        let entry =
          match Hashtbl.find_opt cache key with
          | Some entry -> entry
          | None ->
              Server_utils.evict_oldest_if_full ~max_entries:max_entries
                ~age_of:Cache_state.updated_at cache;
              let entry = Cache_state.empty in
              Hashtbl.add cache key entry;
              entry
        in
        match Cache_state.admit ~now ~ttl_s:ttl_s entry with
        | Cache_state.Reuse view -> view, None
        | Cache_state.Refresh (view, plan) ->
            let entry, owner = Cache_state.start plan in
            Hashtbl.replace cache key entry;
            view, Some owner)
  in
  let response = cache_response ~now ~placeholder view in
  match owner with
  | None -> response
  | Some owner ->
      let was_cold = match view with
        | Cache_state.Warming _ -> true
        | Cache_state.Fresh _ | Cache_state.Stale _ -> false
      in
      if sync_first && was_cold then
        (match run_compute_and_store ~background:false owner with
         | Ok json, refreshed_at ->
             json_with_cache_metadata json
               (cache_metadata ~state:Dashboard_cache_wire.Cache_fresh
                  ~generated_at:refreshed_at ())
         | Error message, refreshed_at ->
             cache_response ~now:refreshed_at ~placeholder
               (Cache_state.Warming { last_error = Some message }))
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
                        : (Yojson.Safe.t, string) result * float)));
              response
            with exn ->
              Eio.Switch.remove_hook hook;
              raise exn)
         with exn ->
           release owner;
           raise exn)

let read ~sync_first ~sw ~cache ~key ~placeholder ~compute =
  read_result ~now:Unix.gettimeofday
    ~sync_first ~sw ~cache ~key ~placeholder ~compute:(fun () -> Ok (compute ()))
