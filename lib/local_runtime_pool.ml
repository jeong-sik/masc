open Printf
open Yojson.Safe.Util

let ( let* ) = Result.bind

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

type lease = {
  runtime_id : string;
}

type assignment = {
  runtime_id : string;
  base_url : string;
  model_name : string;
  max_concurrency : int;
  lease : lease;
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
  | Some raw -> (
      try
        let value = float_of_string (String.trim raw) in
        if value > 0.0 then value else default
      with Failure _ -> default)

let cooldown_seconds () =
  float_of_env_default "MASC_LLAMA_RUNTIME_COOLDOWN_SEC" ~default:30.0

let trim_opt = function
  | None -> None
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed

let debug_enabled () =
  match trim_opt (Sys.getenv_opt "MASC_LLAMA_RUNTIME_DEBUG") with
  | Some ("1" | "true" | "yes" | "on") -> true
  | _ -> false

let debug_log fmt =
  if debug_enabled () then Printf.ksprintf (fun msg -> Eio.traceln "[local_runtime_pool] %s" msg) fmt
  else Printf.ksprintf (fun _ -> ()) fmt

let empty_pool = {
  runtimes = [];
  fingerprint = "";
  parse_errors = [];
  measured_ceiling = None;
}

let pool : pool_state ref = ref empty_pool

let reset () = pool := empty_pool

let parse_int_opt raw =
  try Some (int_of_string (String.trim raw)) with Failure _ -> None

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
    model = trim_opt (Sys.getenv_opt "LLAMA_SWARM_MODEL");
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

let current_fingerprint () =
  String.concat "||"
    [
      Option.value ~default:"" (Sys.getenv_opt "MASC_LLAMA_RUNTIMES_JSON");
      Env_config.Llama.server_url;
      Option.value ~default:"" (Sys.getenv_opt "LLAMA_SWARM_MODEL");
      Option.value ~default:""
        (Sys.getenv_opt "MASC_LLAMA_RUNTIME_COOLDOWN_SEC");
      string_of_int
        (int_of_env_default "LLAMA_SERVER_PARALLEL_HINT"
           ~default:default_parallel_hint);
    ]

let load_runtimes_from_env () =
  match trim_opt (Sys.getenv_opt "MASC_LLAMA_RUNTIMES_JSON") with
  | None -> ([ default_runtime () ], [])
  | Some raw -> (
      try
        match Yojson.Safe.from_string raw with
        | `List items ->
            let parsed, errors =
              List.fold_left
                (fun (acc, errs) item ->
                  match normalize_runtime_json item with
                  | Ok runtime -> (runtime :: acc, errs)
                  | Error err -> (acc, err :: errs))
                ([], []) items
            in
            let runtimes = List.rev parsed in
            if runtimes = [] then
              ([ default_runtime () ], "MASC_LLAMA_RUNTIMES_JSON produced no usable runtimes" :: errors)
            else (runtimes, List.rev errors)
        | _ ->
            ([ default_runtime () ], [ "MASC_LLAMA_RUNTIMES_JSON must be a JSON array" ])
      with Yojson.Json_error err ->
        ([ default_runtime () ], [ "invalid MASC_LLAMA_RUNTIMES_JSON: " ^ err ]))

(* ensure_loaded: the only function that may yield (debug_log calls Eio.traceln).
   Yield happens AFTER the ref swap, so callers reading !pool after this
   function returns see a consistent snapshot. *)
let ensure_loaded () =
  let state = !pool in
  let fingerprint = current_fingerprint () in
  if not (String.equal fingerprint state.fingerprint) then begin
    let loaded, errors = load_runtimes_from_env () in
    let refreshed = List.map refresh_runtime_metrics loaded in
    pool := { state with runtimes = refreshed; fingerprint; parse_errors = errors };
    debug_log "reload runtimes count=%d errors=%d" (List.length loaded) (List.length errors)
  end else begin
    let refreshed = List.map refresh_runtime_metrics state.runtimes in
    pool := { state with runtimes = refreshed }
  end

let parse_errors () =
  ensure_loaded ();
  (!pool).parse_errors

let snapshots () =
  ensure_loaded ();
  List.map runtime_to_snapshot (!pool).runtimes

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

let measured_ceiling () = (!pool).measured_ceiling

let record_measured_ceiling value =
  let state = !pool in
  let bounded = max 0 value in
  let new_ceiling =
    match state.measured_ceiling with
    | Some current -> Some (max current bounded)
    | None -> Some bounded
  in
  pool := { state with measured_ceiling = new_ceiling }

let model_name_for_runtime (runtime : runtime) requested_model =
  match trim_opt requested_model with
  | Some model -> Ok model
  | None -> (
      match runtime.model with
      | Some model -> Ok model
      | None ->
          Error
            (sprintf
               "no explicit llama model provided for runtime %s; set spawn_model or runtime.model"
               runtime.id))

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
  | [] -> Error "no local llama runtimes configured"
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
                         "no local llama runtime configured for model %s%s"
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
                (sprintf "no local llama runtime configured for model %s" requested)
          | None -> Error "no local llama runtimes configured")

(* Backward-compatible wrapper that loads from env first. *)
let select_runtime ?preferred_pool ?model_name () =
  ensure_loaded ();
  select_runtime_from (!pool).runtimes ?preferred_pool ?model_name ()

(* acquire: ensure_loaded may yield (Eio.traceln inside debug_log).
   After that, reading !pool and swapping pool := are yield-free. *)
let acquire ?preferred_pool ~model_name () =
  ensure_loaded ();
  (* --- yield-free critical section --- *)
  let state : pool_state = !pool in
  let* runtime = select_runtime_from state.runtimes ?preferred_pool ?model_name () in
  let* model_name = model_name_for_runtime runtime model_name in
  let updated = { runtime with
    active_slots = runtime.active_slots + 1;
    queue_depth = max 0 (runtime.active_slots + 1 - runtime.max_concurrency);
    total_started = runtime.total_started + 1;
  } in
  let new_runtimes : runtime list =
    List.map
      (fun (r : runtime) ->
        if String.equal r.id runtime.id then updated else r)
      (state.runtimes : runtime list)
  in
  pool := { state with runtimes = new_runtimes };
  (* --- end critical section --- *)
  Ok
    {
      runtime_id = runtime.id;
      base_url = runtime.base_url;
      model_name;
      max_concurrency = runtime.max_concurrency;
      lease = { runtime_id = runtime.id };
    }

(* release: ensure_loaded may yield. After that, ref read+swap is yield-free.
   debug_log (may yield) is placed AFTER the ref swap. *)
let release (lease : lease) ~success ?error ?latency_ms () =
  ensure_loaded ();
  (* --- yield-free critical section --- *)
  let state : pool_state = !pool in
  match
    List.find_opt
      (fun (runtime : runtime) -> String.equal runtime.id lease.runtime_id)
      state.runtimes
  with
  | None -> ()
  | Some runtime ->
      let before_failure_streak = runtime.failure_streak in
      let active_slots = max 0 (runtime.active_slots - 1) in
      let latency_ema_ms =
        match latency_ms with
        | Some latency ->
            let latency = float_of_int (max 0 latency) in
            Some
              (match runtime.latency_ema_ms with
               | None -> latency
               | Some previous -> (previous *. 0.8) +. (latency *. 0.2))
        | None -> runtime.latency_ema_ms
      in
      let failure_streak, cooldown_until, last_error, total_success, total_failure =
        if success then
          (0, None, None, runtime.total_success + 1, runtime.total_failure)
        else
          let streak = runtime.failure_streak + 1 in
          let cooldown =
            if streak >= 3 then Some (wall_now () +. cooldown_seconds ())
            else runtime.cooldown_until
          in
          (streak, cooldown, trim_opt error, runtime.total_success, runtime.total_failure + 1)
      in
      let queue_depth = max 0 (active_slots - runtime.max_concurrency) in
      let updated = { runtime with
        active_slots; queue_depth; latency_ema_ms;
        failure_streak; cooldown_until; last_error;
        total_success; total_failure;
      } in
      let new_runtimes : runtime list =
        List.map
          (fun (r : runtime) ->
            if String.equal r.id runtime.id then updated else r)
          (state.runtimes : runtime list)
      in
      pool := { state with runtimes = new_runtimes };
      (* --- end critical section --- *)
      debug_log
        "release runtime=%s success=%b before_streak=%d after_streak=%d cooldown=%s total_success=%d total_failure=%d error=%s"
        runtime.id success before_failure_streak updated.failure_streak
        (match updated.cooldown_until with
         | Some value -> Printf.sprintf "%.3f" value
         | None -> "null")
        updated.total_success updated.total_failure
        (Option.value ~default:"" (trim_opt error))

let model_spec_of_assignment (assignment : assignment) =
  {
    Llm.llama_default with
    model_id = assignment.model_name;
    api_url = assignment.base_url;
  }

let snapshot_to_yojson (snapshot : runtime_snapshot) =
  `Assoc
    [
      ("id", `String snapshot.id);
      ("base_url", `String snapshot.base_url);
      ( "model",
        match snapshot.model with Some value -> `String value | None -> `Null );
      ("max_concurrency", `Int snapshot.max_concurrency);
      ("active_slots", `Int snapshot.active_slots);
      ("queue_depth", `Int snapshot.queue_depth);
      ( "latency_ema_ms",
        match snapshot.latency_ema_ms with
        | Some value -> `Float value
        | None -> `Null );
      ("failure_streak", `Int snapshot.failure_streak);
      ( "cooldown_until",
        match snapshot.cooldown_until with
        | Some value -> `Float value
        | None -> `Null );
      ( "last_error",
        match snapshot.last_error with
        | Some value -> `String value
        | None -> `Null );
      ("total_started", `Int snapshot.total_started);
      ("total_success", `Int snapshot.total_success);
      ("total_failure", `Int snapshot.total_failure);
      ("port", match snapshot.port with Some value -> `Int value | None -> `Null);
    ]
