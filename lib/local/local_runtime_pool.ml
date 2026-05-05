open Printf
open Yojson.Safe.Util

open Result.Syntax

type runtime = {
  id : string;
  base_url : string;
  model : string option;
  max_concurrency : int;
  active_slots : int;
  queue_depth : int;
  latency_ema_ms : float option;
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
  latency_ema_ms : float option;
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
  measured_ceiling : int option;
}

let default_pool_label = "local64"
let default_parallel_hint = 12

let wall_now () = Unix.gettimeofday ()

let float_of_env_default name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      match float_of_string_opt (String.trim raw) with
      | Some value when value > 0.0 -> value
      | _ -> default

let cooldown_seconds () =
  match Env_config.Worker.local_runtime_cooldown_sec_opt () with
  | Some raw ->
      (match float_of_string_opt (String.trim raw) with
       | Some value when value > 0.0 -> value
       | _ -> 30.0)
  | None -> 30.0

let trim_opt = function
  | None -> None
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed

let debug_enabled () = Env_config.Worker.local_runtime_debug

let debug_log fmt =
  if debug_enabled () then Printf.ksprintf (fun msg -> Log.LocalWorker.debug "%s" msg) fmt
  else Printf.ksprintf (fun _ -> ()) fmt

let empty_pool = {
  runtimes = [];
  fingerprint = "";
  parse_errors = [];
  measured_ceiling = None;
}

let pool : pool_state ref = ref empty_pool
let pool_mu = Eio.Mutex.create ()

let with_pool_lock f = Eio_guard.with_mutex pool_mu f

let reset () = with_pool_lock (fun () -> pool := empty_pool)

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
    latency_ema_ms = None;
    failure_streak = if status.healthy then 0 else 1;
    cooldown_until = unavailable;
    last_error =
      if status.healthy then None else Some "oas discovery marked endpoint unhealthy";
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
    latency_ema_ms = None;
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
    latency_ema_ms = runtime.latency_ema_ms;
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

let normalize_runtime_json json =
  let base_url = json |> member "base_url" |> to_string_option |> trim_opt in
  match base_url with
  | None -> Error "runtime.base_url is required"
  | Some base_url ->
      let id =
        json |> member "id" |> to_string_option |> trim_opt
        |> Option.value ~default:(runtime_id_of_base_url base_url)
      in
      let model = json |> member "model" |> to_string_option |> trim_opt in
      let max_concurrency =
        match json |> member "max_concurrency" with
        | `Int value -> max 1 value
        | `Intlit raw -> (
            match parse_int_opt raw with
            | Some value -> max 1 value
            | None -> default_parallel_hint)
        | _ -> default_parallel_hint
      in
      Ok
        {
          id;
          base_url;
          model;
          max_concurrency;
          active_slots = 0;
          queue_depth = 0;
          latency_ema_ms = None;
          failure_streak = 0;
          cooldown_until = None;
          last_error = None;
          total_started = 0;
          total_success = 0;
          total_failure = 0;
        }

let default_runtime () =
  let base_url = Env_config.Llama.server_url in
  {
    id = runtime_id_of_base_url base_url;
    base_url;
    model = trim_opt (Env_config.Local_runtime.worker_model_opt ());
    max_concurrency =
      int_of_env_default "LLAMA_SERVER_PARALLEL_HINT" ~default:default_parallel_hint;
    active_slots = 0;
    queue_depth = 0;
    latency_ema_ms = None;
    failure_streak = 0;
    cooldown_until = None;
    last_error = None;
    total_started = 0;
    total_success = 0;
    total_failure = 0;
  }

let runtime_from_endpoint base_url =
  {
    id = runtime_id_of_base_url base_url;
    base_url;
    model = trim_opt (Env_config.Local_runtime.worker_model_opt ());
    max_concurrency =
      int_of_env_default "LLAMA_SERVER_PARALLEL_HINT"
        ~default:default_parallel_hint;
    active_slots = 0;
    queue_depth = 0;
    latency_ema_ms = None;
    failure_streak = 0;
    cooldown_until = None;
    last_error = None;
    total_started = 0;
    total_success = 0;
    total_failure = 0;
  }

let parse_llm_endpoints raw =
  raw
  |> String.split_on_char ','
  |> List.filter_map (fun item -> trim_opt (Some item))
  |> List.map runtime_from_endpoint

let current_fingerprint () =
  String.concat "||"
    [
      String.concat "," (Llm_provider.Discovery.endpoints_from_env ());
      Env_config.Llama.server_url;
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
      let endpoints = Llm_provider.Discovery.endpoints_from_env () in
      let runtimes = List.map runtime_of_endpoint_url endpoints in
      if runtimes = [] then ([ default_runtime () ], []) else (runtimes, [])

(* ensure_loaded: the only function that may yield (debug_log calls Log.LocalWorker.debug).
   Yield happens AFTER the ref swap, so callers reading !pool after this
   function returns see a consistent snapshot.

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
    with_pool_lock (fun () -> not (String.equal fingerprint (!pool).fingerprint))
  in
  if needs_reload then begin
    let loaded, errors = load_runtimes_from_env () in
    let loaded_fingerprint = current_fingerprint () in
    if String.equal loaded_fingerprint fingerprint then begin
      let refreshed = List.map refresh_runtime_metrics loaded in
      let reloaded =
        with_pool_lock (fun () ->
          let state = !pool in
          if not (String.equal fingerprint state.fingerprint) then begin
            pool := { state with runtimes = refreshed; fingerprint; parse_errors = errors };
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
      let state = !pool in
      let refreshed = List.map refresh_runtime_metrics state.runtimes in
      pool := { state with runtimes = refreshed })
  end

let parse_errors () =
  ensure_loaded ();
  with_pool_lock (fun () -> (!pool).parse_errors)

let snapshots () =
  ensure_loaded ();
  with_pool_lock (fun () -> List.map runtime_to_snapshot (!pool).runtimes)

let configured_capacity () =
  snapshots ()
  |> List.fold_left
       (fun acc (runtime : runtime_snapshot) -> acc + runtime.max_concurrency)
       0

let healthy_runtime_count () =
  snapshots ()
  |> List.fold_left
       (fun acc (runtime : runtime_snapshot) ->
         match runtime.cooldown_until with
         | Some until_ts when until_ts > Time_compat.now () -> acc
         | _ -> acc + 1)
       0

let allocated_slots () =
  snapshots ()
  |> List.fold_left
       (fun acc (runtime : runtime_snapshot) -> acc + runtime.active_slots)
       0

let measured_ceiling () = with_pool_lock (fun () -> (!pool).measured_ceiling)

let record_measured_ceiling value =
  with_pool_lock (fun () ->
    let state = !pool in
    let bounded = max 0 value in
    let new_ceiling =
      match state.measured_ceiling with
      | Some current -> Some (max current bounded)
      | None -> Some bounded
    in
    pool := { state with measured_ceiling = new_ceiling })

let preference_matches (runtime : runtime) preferred_pool =
  match trim_opt preferred_pool with
  | None -> true
  | Some preferred ->
      String.equal preferred default_pool_label
      || String.equal preferred "default"
      || String.equal runtime.id preferred

let runtime_matches_requested_model (runtime : runtime) requested_model =
  match trim_opt requested_model with
  | None -> `Any
  | Some requested -> (
      match runtime.model with
      | Some configured when String.equal configured requested -> `Exact
      | None -> `Generic
      | Some _ -> `Mismatch)

let runtime_sort_key (runtime : runtime) =
  let overload = max 0 (runtime.active_slots - runtime.max_concurrency) in
  let latency =
    match runtime.latency_ema_ms with Some value -> int_of_float value | None -> 0
  in
  (overload, runtime.active_slots, latency, runtime.failure_streak, runtime.id)

(* Pure selection — no side effects, no Eio calls. *)
let select_runtime_from (runtimes : runtime list) ?preferred_pool ?model_name () :
    (runtime, string) result =
  let matching =
    List.filter (fun runtime -> preference_matches runtime preferred_pool) runtimes
  in
  let matching = if matching = [] then runtimes else matching in
  match matching with
  | [] -> Error "no local runtimes configured"
  | runtimes ->
      let requested_model = trim_opt model_name in
      let exact_model_matches =
        List.filter
          (fun runtime ->
            match runtime_matches_requested_model runtime requested_model with
            | `Exact -> true
            | _ -> false)
          runtimes
      in
      let generic_model_matches =
        List.filter
          (fun runtime ->
            match runtime_matches_requested_model runtime requested_model with
            | `Generic -> true
            | _ -> false)
          runtimes
      in
      let candidate_runtimes_result =
        match requested_model with
        | None -> Ok runtimes
        | Some requested -> (
            match exact_model_matches with
            | _ :: _ -> Ok exact_model_matches
            | [] -> (
                match generic_model_matches with
                | _ :: _ -> Ok generic_model_matches
                | [] ->
                    let scope =
                      match trim_opt preferred_pool with
                      | Some pool -> sprintf " in runtime pool %s" pool
                      | None -> ""
                    in
                    Error
                      (sprintf
                         "no local runtime configured for model %s%s"
                         requested scope)))
      in
      let* runtimes = candidate_runtimes_result in
      let now = Time_compat.now () in
      let healthy =
        List.filter
          (fun (runtime : runtime) ->
            match runtime.cooldown_until with
            | Some until_ts when until_ts > now -> false
            | _ -> true)
          runtimes
      in
      let candidates = if healthy = [] then runtimes else healthy in
      let sorted =
        List.sort (fun a b -> compare (runtime_sort_key a) (runtime_sort_key b))
          candidates
      in
      match sorted with
      | runtime :: _ -> Ok runtime
      | [] -> (
          match requested_model with
          | Some requested ->
              Error
                (sprintf "no local runtime configured for model %s" requested)
          | None -> Error "no local runtimes configured")

(* [acquire] / [release] / [model_label_of_assignment] removed 2026-05-05 —
   zero production callers; see [docs/audit-responses/2026-05-05-dashboard-heuristic.md]
   §7.1. If leasing semantics return, design at the OAS cascade layer per RFC-0026. *)

let snapshot_to_yojson (snapshot : runtime_snapshot) =
  `Assoc
    [
      ("id", `String snapshot.id);
      ("base_url", `String snapshot.base_url);
      ("model", Json_util.string_opt_to_json snapshot.model);
      ("max_concurrency", `Int snapshot.max_concurrency);
      ("active_slots", `Int snapshot.active_slots);
      ("queue_depth", `Int snapshot.queue_depth);
      ("latency_ema_ms", Json_util.float_opt_to_json snapshot.latency_ema_ms);
      ("failure_streak", `Int snapshot.failure_streak);
      ("cooldown_until", Json_util.float_opt_to_json snapshot.cooldown_until);
      ("last_error", Json_util.string_opt_to_json snapshot.last_error);
      ("total_started", `Int snapshot.total_started);
      ("total_success", `Int snapshot.total_success);
      ("total_failure", `Int snapshot.total_failure);
      ("port", Json_util.int_opt_to_json snapshot.port);
    ]
