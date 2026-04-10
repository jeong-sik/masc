type dashboard_compute_mode =
  | Inline_shared
  | Offloaded_readonly

type runtime = {
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t;
}

type t = {
  mutable cached_readonly_pg_config : Room.config option;
  readonly_config_mu : Eio.Mutex.t;
  mutable pg_semaphore : Eio.Semaphore.t option;
}

let create () =
  {
    cached_readonly_pg_config = None;
    readonly_config_mu = Eio.Mutex.create ();
    pg_semaphore = None;
  }

let default_state : t = create ()

let default () = default_state

let set_executor_pool pool = Executor_pool_ref.set pool

let isolated_readonly_dashboard_config ~runtime ~sw ~clock ~(config : Room.config) =
  match config.backend_config.Backend.backend_type with
  | Backend.PostgresNative ->
      Room_utils_backend_setup.with_domain_local_pg_backend
        ~sw ~net:runtime.net ~clock ~mono_clock:runtime.mono_clock config
  | Backend.Memory | Backend.FileSystem -> Some config

let cached_isolated_readonly_config state ~runtime ~sw ~clock ~config =
  match state.cached_readonly_pg_config with
  | Some c -> Some c
  | None ->
      Eio.Mutex.use_rw ~protect:true state.readonly_config_mu (fun () ->
          match state.cached_readonly_pg_config with
          | Some c -> Some c
          | None ->
              let result =
                isolated_readonly_dashboard_config ~runtime ~sw ~clock ~config
              in
              (match result with
              | Some config ->
                  state.cached_readonly_pg_config <- Some config;
                  Log.Dashboard.info "cached main-domain readonly PG config"
              | None -> ());
              result)

let pg_semaphore state () =
  match state.pg_semaphore with
  | Some s -> s
  | None ->
      let pool_size = Env_config_core.pg_pool_size () in
      let limit = max 2 (pool_size - 2) in
      let s = Eio.Semaphore.make limit in
      state.pg_semaphore <- Some s;
      Log.Dashboard.info "PG dashboard semaphore created (limit=%d)" limit;
      s

let with_pg_guard state f =
  let sem = pg_semaphore state () in
  Eio.Semaphore.acquire sem;
  Fun.protect ~finally:(fun () -> Eio.Semaphore.release sem) f

let require_runtime = function
  | Some runtime -> runtime
  | None ->
      invalid_arg
        "dashboard readonly Postgres compute requires threaded net and mono_clock"

let run_dashboard_compute state ?(mode = Offloaded_readonly) ?runtime ~sw ~clock
    ~(config : Room.config) compute =
  let fallback () = compute ~config ~sw in
  let fallback_isolated_pg () =
    let runtime = require_runtime runtime in
    match cached_isolated_readonly_config state ~runtime ~sw ~clock ~config with
    | Some isolated -> compute ~config:isolated ~sw
    | None ->
        Log.Dashboard.warn
          "dashboard readonly backend unavailable; using shared backend";
        fallback ()
  in
  let run_in_pool pool_sw =
    match config.backend_config.Backend_types.backend_type with
    | Backend_types.PostgresNative ->
        let runtime = require_runtime runtime in
        (match
           Room_utils_backend_setup.with_domain_local_pg_backend
             ~sw:pool_sw ~net:runtime.net ~clock
             ~mono_clock:runtime.mono_clock config
         with
        | Some domain_config -> `Done (compute ~config:domain_config ~sw:pool_sw)
        | None -> `Fallback)
    | Backend_types.Memory | Backend_types.FileSystem ->
        `Done (compute ~config ~sw:pool_sw)
  in
  let is_pg =
    config.backend_config.Backend.backend_type = Backend.PostgresNative
  in
  let offloaded () =
    match Executor_pool_ref.get () with
    | Some pool -> (
        try
          match
            Eio.Executor_pool.submit_exn pool ~weight:1.0 (fun () ->
                Eio.Switch.run run_in_pool)
          with
          | `Done value -> value
          | `Fallback ->
              Log.Dashboard.warn
                "dashboard offload fallback: domain-local backend unavailable";
              if is_pg then with_pg_guard state fallback_isolated_pg else fallback ()
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Dashboard.warn
              "dashboard offload failed, using inline compute: %s"
              (Printexc.to_string exn);
            if is_pg then with_pg_guard state fallback_isolated_pg else fallback ())
    | None ->
        if is_pg then with_pg_guard state fallback_isolated_pg else fallback ()
  in
  match mode with
  | Inline_shared -> fallback ()
  | Offloaded_readonly ->
      (* All backends offload to executor pool when available.
         FileSystem: key_index protected by Stdlib.Mutex (domain-safe),
         file I/O by Eio.Mutex (domain-safe via Stdlib.Mutex internally).
         Memory: Eio_guard.with_mutex delegates to Eio.Mutex (domain-safe).
         PG: creates domain-local connection pool (already supported).
         Offloading isolates dashboard compute from keeper turns on the
         main domain, eliminating contention-induced latency spikes. *)
      offloaded ()

let dashboard_active_or_recent_sessions_cached _state ~clock:_
    ~refresh_interval_s:_ _config _load_sessions =
  (* Team session store removed — always empty. *)
  []
