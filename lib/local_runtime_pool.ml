open Printf
open Yojson.Safe.Util

let ( let* ) = Result.bind

type runtime = {
  id : string;
  base_url : string;
  model : string option;
  max_concurrency : int;
  mutable active_slots : int;
  mutable queue_depth : int;
  mutable latency_ema_ms : float option;
  mutable failure_streak : int;
  mutable cooldown_until : float option;
  mutable last_error : string option;
  mutable total_started : int;
  mutable total_success : int;
  mutable total_failure : int;
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

let default_pool_label = "local64"
let default_parallel_hint = 12
let cooldown_seconds = 30.0

let runtimes : runtime list ref = ref []
let runtimes_fingerprint = ref ""
let runtime_parse_errors : string list ref = ref []
let measured_ceiling_ref : int option ref = ref None

let trim_opt = function
  | None -> None
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed

let parse_int_opt raw =
  try Some (int_of_string (String.trim raw)) with _ -> None

let int_of_env_default name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      match parse_int_opt raw with
      | Some value when value > 0 -> value
      | _ -> default)

let runtime_port base_url =
  try Uri.of_string base_url |> Uri.port with _ -> None

let runtime_id_of_base_url base_url =
  match runtime_port base_url with
  | Some port -> sprintf "llama-%d" port
  | None ->
      let digest = Digest.string base_url |> Digest.to_hex in
      sprintf "llama-%s" (String.sub digest 0 8)

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
  runtime.queue_depth <- max 0 (runtime.active_slots - runtime.max_concurrency);
  match runtime.cooldown_until with
  | Some until_ts when until_ts <= Time_compat.now () ->
      runtime.cooldown_until <- None;
      runtime.failure_streak <- 0
  | _ -> ()

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

let ensure_loaded () =
  let fingerprint = current_fingerprint () in
  if not (String.equal fingerprint !runtimes_fingerprint) then (
    let loaded, errors = load_runtimes_from_env () in
    runtimes := loaded;
    runtime_parse_errors := errors;
    runtimes_fingerprint := fingerprint);
  List.iter refresh_runtime_metrics !runtimes

let parse_errors () =
  ensure_loaded ();
  !runtime_parse_errors

let snapshots () =
  ensure_loaded ();
  List.map runtime_to_snapshot !runtimes

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

let measured_ceiling () = !measured_ceiling_ref

let record_measured_ceiling value =
  let bounded = max 0 value in
  measured_ceiling_ref :=
    (match !measured_ceiling_ref with
     | Some current -> Some (max current bounded)
     | None -> Some bounded)

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

let runtime_sort_key (runtime : runtime) =
  let overload = max 0 (runtime.active_slots - runtime.max_concurrency) in
  let latency =
    match runtime.latency_ema_ms with Some value -> int_of_float value | None -> 0
  in
  (overload, runtime.active_slots, latency, runtime.failure_streak, runtime.id)

let select_runtime ?preferred_pool () =
  ensure_loaded ();
  let matching =
    List.filter (fun runtime -> preference_matches runtime preferred_pool) !runtimes
  in
  let matching = if matching = [] then !runtimes else matching in
  match matching with
  | [] -> Error "no local llama runtimes configured"
  | runtimes ->
      let now = Time_compat.now () in
      let healthy =
        List.filter
          (fun (runtime : runtime) ->
            match runtime.cooldown_until with
            | Some until_ts when until_ts > now -> false
            | _ -> true)
          runtimes
      in
      let pool = if healthy = [] then runtimes else healthy in
      let sorted = List.sort (fun a b -> compare (runtime_sort_key a) (runtime_sort_key b)) pool in
      match sorted with
      | runtime :: _ -> Ok runtime
      | [] -> Error "no local llama runtimes configured"

let acquire ?preferred_pool ~model_name () =
  let* runtime = select_runtime ?preferred_pool () in
  let* model_name = model_name_for_runtime runtime model_name in
  runtime.active_slots <- runtime.active_slots + 1;
  refresh_runtime_metrics runtime;
  runtime.total_started <- runtime.total_started + 1;
  Ok
    {
      runtime_id = runtime.id;
      base_url = runtime.base_url;
      model_name;
      max_concurrency = runtime.max_concurrency;
      lease = { runtime_id = runtime.id };
    }

let release (lease : lease) ~success ?error ?latency_ms () =
  ensure_loaded ();
  match
    List.find_opt
      (fun (runtime : runtime) -> String.equal runtime.id lease.runtime_id)
      !runtimes
  with
  | None -> ()
  | Some runtime ->
      runtime.active_slots <- max 0 (runtime.active_slots - 1);
      refresh_runtime_metrics runtime;
      (match latency_ms with
       | Some latency ->
           let latency = float_of_int (max 0 latency) in
           runtime.latency_ema_ms <-
             Some
               (match runtime.latency_ema_ms with
                | None -> latency
                | Some previous -> (previous *. 0.8) +. (latency *. 0.2))
       | None -> ());
      if success then (
        runtime.failure_streak <- 0;
        runtime.cooldown_until <- None;
        runtime.last_error <- None;
        runtime.total_success <- runtime.total_success + 1)
      else (
        runtime.failure_streak <- runtime.failure_streak + 1;
        runtime.last_error <- trim_opt error;
        runtime.total_failure <- runtime.total_failure + 1;
        if runtime.failure_streak >= 3 then
          runtime.cooldown_until <- Some (Time_compat.now () +. cooldown_seconds))

let model_spec_of_assignment (assignment : assignment) =
  {
    Llm_client.llama_default with
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
