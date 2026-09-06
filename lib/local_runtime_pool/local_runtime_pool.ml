open Printf

type runtime = {
  id : string;
  base_url : string;
  model : string option;
  max_concurrency : int;
  active_slots : int;
  queue_depth : int;
  failure_streak : int;
  cooldown_until : float option;
  last_error : string option;
  total_started : int;
  total_success : int;
  total_failure : int;
}

type runtime_snapshot = {
  id : string;
  base_url : string;
  model : string option;
  max_concurrency : int;
  active_slots : int;
  queue_depth : int;
  failure_streak : int;
  cooldown_until : float option;
  last_error : string option;
  total_started : int;
  total_success : int;
  total_failure : int;
  port : int option;
}

type pool_state = {
  runtimes : runtime list;
  fingerprint : string;
  parse_errors : string list;
}

let default_pool_label = "local64"
let default_parallel_hint = 12

let wall_now () = Unix.gettimeofday ()

let cooldown_seconds () =
  match Env_config.Worker.local_runtime_cooldown_sec_opt () with
  | Some raw ->
      (match float_of_string_opt (String.trim raw) with
       | Some value when value > 0.0 -> value
       | _ -> 30.0)
  | None -> 30.0

let trim_opt = Env_config_core.trim_opt

let debug_enabled () = Env_config.Worker.local_runtime_debug

let debug_log fmt =
  if debug_enabled () then Printf.ksprintf (fun msg -> Log.LocalWorker.debug "%s" msg) fmt
  else Printf.ksprintf (fun _ -> ()) fmt

let empty_pool = {
  runtimes = [];
  fingerprint = "";
  parse_errors = [];
}

let pool : pool_state Atomic.t = Atomic.make empty_pool
let pool_mu = Stdlib.Mutex.create ()

let with_pool_lock f = Stdlib.Mutex.protect pool_mu f

let reset () = with_pool_lock (fun () -> Atomic.set pool empty_pool)

let parse_int_opt raw =
  int_of_string_opt ((String.trim raw))

let int_of_env_default name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      match parse_int_opt raw with
      | Some value when value > 0 -> value
      | _ -> default)

let runtime_port base_url =
  try Uri.of_string base_url |> Uri.port with Failure _ -> None

let runtime_id_of_base_url base_url =
  match runtime_port base_url with
  | Some port -> sprintf "local-%d" port
  | None ->
      let digest = Digest.string base_url |> Digest.to_hex in
      sprintf "local-%s" (String.sub digest 0 8)

let model_of_discovery_status (status : Discovery_cache.endpoint_info) =
  match status.models with
  | model :: _ -> trim_opt (Some model.id)
  | [] -> (
      match status.props with
      | Some props -> trim_opt (Some props.model)
      | None -> trim_opt (Env_config.Local_runtime.worker_model_opt ()))

let max_concurrency_of_discovery_status (status : Discovery_cache.endpoint_info) =
  match status.slots with
  | Some slots when slots.total > 0 -> slots.total
  | _ ->
      int_of_env_default "LLAMA_SERVER_PARALLEL_HINT"
        ~default:default_parallel_hint

let runtime_of_discovery_status (status : Discovery_cache.endpoint_info) =
  let base_url = String.trim status.url in
  let unavailable =
    if status.healthy then None else Some (wall_now () +. cooldown_seconds ())
  in
  {
    id = runtime_id_of_base_url base_url;
    base_url;
    model = model_of_discovery_status status;
    max_concurrency = max_concurrency_of_discovery_status status;
    active_slots = 0;
    queue_depth = 0;
    failure_streak = if status.healthy then 0 else 1;
    cooldown_until = unavailable;
    last_error =
      if status.healthy then None else Some "agent_core discovery marked endpoint unhealthy";
    total_started = 0;
    total_success = 0;
    total_failure = 0;
  }

let runtime_of_endpoint_url base_url =
  let base_url = String.trim base_url in
  {
    id = runtime_id_of_base_url base_url;
    base_url;
    model = trim_opt (Env_config.Local_runtime.worker_model_opt ());
    max_concurrency =
      int_of_env_default "LLAMA_SERVER_PARALLEL_HINT"
        ~default:default_parallel_hint;
    active_slots = 0;
    queue_depth = 0;
    failure_streak = 0;
    cooldown_until = None;
    last_error = None;
    total_started = 0;
    total_success = 0;
    total_failure = 0;
  }

let safe_discovery_statuses () =
  try Discovery_cache.get_cached_or_refresh ()
  with
  | Stdlib.Effect.Unhandled _ -> []
  | exn ->
      debug_log "discovery_cache unavailable: %s" (Printexc.to_string exn);
      []

let runtime_to_snapshot (runtime : runtime) =
  {
    id = runtime.id;
    base_url = runtime.base_url;
    model = runtime.model;
    max_concurrency = runtime.max_concurrency;
    active_slots = runtime.active_slots;
    queue_depth = runtime.queue_depth;
    failure_streak = runtime.failure_streak;
    cooldown_until = runtime.cooldown_until;
    last_error = runtime.last_error;
    total_started = runtime.total_started;
    total_success = runtime.total_success;
    total_failure = runtime.total_failure;
    port = runtime_port runtime.base_url;
  }

let refresh_runtime_metrics (runtime : runtime) =
  let queue_depth = max 0 (runtime.active_slots - runtime.max_concurrency) in
  match runtime.cooldown_until with
  | Some until_ts when until_ts <= wall_now () ->
      { runtime with queue_depth; cooldown_until = None; failure_streak = 0 }
  | _ -> { runtime with queue_depth }

let default_runtime () =
  let base_url = Env_config.Local_runtime.server_url in
  {
    id = runtime_id_of_base_url base_url;
    base_url;
    model = trim_opt (Env_config.Local_runtime.worker_model_opt ());
    max_concurrency =
      int_of_env_default "LLAMA_SERVER_PARALLEL_HINT" ~default:default_parallel_hint;
    active_slots = 0;
    queue_depth = 0;
    failure_streak = 0;
    cooldown_until = None;
    last_error = None;
    total_started = 0;
    total_success = 0;
    total_failure = 0;
  }

let current_fingerprint () =
  String.concat "||"
    [
      String.concat "," (Llm_provider.Discovery.parse_llm_endpoints_env ());
      Env_config.Local_runtime.server_url;
      Option.value ~default:"" (Env_config.Local_runtime.worker_model_opt ());
      Option.value ~default:""
        (Env_config.Worker.local_runtime_cooldown_sec_opt ());
      string_of_int
        (int_of_env_default "LLAMA_SERVER_PARALLEL_HINT"
           ~default:default_parallel_hint);
    ]

let load_runtimes_from_env () =
  let discovered =
    safe_discovery_statuses () |> List.map runtime_of_discovery_status
  in
  match discovered with
  | _ :: _ -> (discovered, [])
  | [] ->
      let endpoints = Llm_provider.Discovery.parse_llm_endpoints_env () in
      let runtimes = List.map runtime_of_endpoint_url endpoints in
      if runtimes = [] then ([ default_runtime () ], []) else (runtimes, [])

(* ensure_loaded: the only function that may yield (debug_log calls Log.LocalWorker.debug).
   Yield happens AFTER the atomic swap, so later callers see a consistent
   snapshot.

   The [load_runtimes_from_env] call and the fingerprint paired with it
   must be captured atomically: both functions read environment
   variables, and if env changes between them the installed
   [(fingerprint, runtimes)] pair would be inconsistent (e.g.
   fingerprint X with Y-era runtimes).  To avoid that, re-read the
   fingerprint immediately after [load_runtimes_from_env] and only
   install if the environment still looks like what we loaded.  If the
   env flipped mid-load, we drop the work and let the next caller
   (which will capture the new fingerprint at the top of its own
   [ensure_loaded] call) redo the load for the current state. *)
let ensure_loaded () =
  let fingerprint = current_fingerprint () in
  let needs_reload =
    with_pool_lock (fun () ->
      not (String.equal fingerprint (Atomic.get pool).fingerprint))
  in
  if needs_reload then begin
    let loaded, errors = load_runtimes_from_env () in
    let loaded_fingerprint = current_fingerprint () in
    if String.equal loaded_fingerprint fingerprint then begin
      let refreshed = List.map refresh_runtime_metrics loaded in
      let reloaded =
        with_pool_lock (fun () ->
          let state = Atomic.get pool in
          if not (String.equal fingerprint state.fingerprint) then begin
            Atomic.set pool
              { runtimes = refreshed; fingerprint; parse_errors = errors };
            true
          end else
            false)
      in
      if reloaded then
        debug_log "reload runtimes count=%d errors=%d" (List.length loaded)
          (List.length errors)
    end else
      (* Env changed mid-load: drop this attempt.  The next caller will
         capture [loaded_fingerprint] at its own top and redo the load
         against the current env snapshot. *)
      debug_log "env drift during reload (captured=%s, post-load=%s); skipping install"
        fingerprint loaded_fingerprint
  end else begin
    with_pool_lock (fun () ->
      let state = Atomic.get pool in
      let refreshed = List.map refresh_runtime_metrics state.runtimes in
      Atomic.set pool { state with runtimes = refreshed })
  end

let snapshots () =
  ensure_loaded ();
  with_pool_lock (fun () ->
    List.map runtime_to_snapshot (Atomic.get pool).runtimes)

module For_testing = struct
  let install_pool runtimes =
    let fingerprint = current_fingerprint () in
    with_pool_lock (fun () ->
      Atomic.set pool { empty_pool with runtimes; fingerprint })
end

(* [acquire] / [release] / [model_label_of_assignment] removed 2026-05-05 —
   zero production callers; see [docs/audit-responses/2026-05-05-dashboard-heuristic.md]
   §7.1. If leasing semantics return, design at the AGENT_CORE runtime layer per RFC-0026. *)

let snapshot_to_yojson (snapshot : runtime_snapshot) =
  `Assoc
    [
      ("id", `String snapshot.id);
      ("base_url", `String snapshot.base_url);
      ("model", Json_util.string_opt_to_json snapshot.model);
      ("max_concurrency", `Int snapshot.max_concurrency);
      ("active_slots", `Int snapshot.active_slots);
      ("queue_depth", `Int snapshot.queue_depth);
      ("failure_streak", `Int snapshot.failure_streak);
      ("cooldown_until", Json_util.float_opt_to_json snapshot.cooldown_until);
      ("last_error", Json_util.string_opt_to_json snapshot.last_error);
      ("total_started", `Int snapshot.total_started);
      ("total_success", `Int snapshot.total_success);
      ("total_failure", `Int snapshot.total_failure);
      ("port", Json_util.int_opt_to_json snapshot.port);
    ]
