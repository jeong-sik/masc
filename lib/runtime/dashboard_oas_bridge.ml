(** See [Dashboard_oas_bridge.mli]. *)

let broadcast_hook = ref (fun _json -> ())
let set_broadcast_hook f = broadcast_hook := f

let per_provider_cap = 200
let default_duration_ms = 0.0
let default_ttfb_ms = 0.0

type status =
  | Success
  | Error of { transient : bool }
  | Cancelled of { reason : string }
  | Timeout

type sample = {
  provider_id : string;
  model_id : string;
  ttfb_ms : float;
  total_duration_ms : float;
  serialization_ms : float;
  usage_reported : bool;
  input_tokens : int option;
  output_tokens : int option;
  throughput_tokens_per_s : float option;
  cost_usd : float option;
  cache_hit : bool option;
  status : status;
  retry_count : int;
}

(* Guards [table]. Critical sections are short — queue push, fold, or clear.
   Stdlib.Mutex is chosen over Eio.Mutex because record/read may be called
   from different domains, and the section never yields to Eio. Same
   rationale as Dashboard_attribution. *)
let mu = Mutex.create ()

(* Per-provider FIFO. Head = oldest, tail = newest. *)
let table : (string, (sample * float) Queue.t) Hashtbl.t =
  Hashtbl.create 8

let with_lock f =
  Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock mu) f

let status_to_yojson = function
  | Success -> `Assoc [ ("kind", `String "success") ]
  | Error { transient } ->
      `Assoc
        [
          ("kind", `String "error");
          ("transient", `Bool transient);
        ]
  | Cancelled { reason } ->
      `Assoc
        [
          ("kind", `String "cancelled");
          ("reason", `String reason);
        ]
  | Timeout -> `Assoc [ ("kind", `String "timeout") ]

let public_runtime_provider_label =
  Boundary_redaction.to_string Boundary_redaction.runtime_provider_label
;;

let public_runtime_model_label =
  Boundary_redaction.to_string Boundary_redaction.runtime_model_label
;;

let source_label = "oas_runtime_bridge"
let durable_replay_surface = "/api/v1/dashboard/telemetry?source=oas_event"

let retention_json =
  `Assoc
    [
      ("scope", `String "in_process_runtime_lane");
      ("per_provider_cap", `Int per_provider_cap);
      ("durable_replay_surface", `String durable_replay_surface);
    ]

let normalize_sample (s : sample) =
  {
    s with
    provider_id = public_runtime_provider_label;
    model_id = public_runtime_model_label;
  }

let normalize_provider_filter = function
  | Some _ -> Some public_runtime_provider_label
  | None -> None

let sample_to_yojson (s : sample) =
  `Assoc
    [
      ("provider_id", `String public_runtime_provider_label);
      ("model_id", `String public_runtime_model_label);
      ("ttfb_ms", `Float s.ttfb_ms);
      ("total_duration_ms", `Float s.total_duration_ms);
      ("serialization_ms", `Float s.serialization_ms);
      ("usage_reported", `Bool s.usage_reported);
      ("input_tokens", Json_util.int_opt_to_json s.input_tokens);
      ("output_tokens", Json_util.int_opt_to_json s.output_tokens);
      ( "throughput_tokens_per_s",
        Json_util.float_opt_to_json s.throughput_tokens_per_s );
      ("cost_usd", Json_util.float_opt_to_json s.cost_usd);
      ("cache_hit", Json_util.bool_opt_to_json s.cache_hit);
      ("status", status_to_yojson s.status);
      ("retry_count", `Int s.retry_count);
    ]

let sample_entry_to_yojson (s, recorded_at) =
  `Assoc
    [
      ("sample", sample_to_yojson s);
      ("recorded_at", `Float recorded_at);
    ]

let provider_json = function
  | Some _ -> `String public_runtime_provider_label
  | None -> `Null

let broadcast_sample_entry entry =
  let sample, recorded_at = entry in
  let json =
    `Assoc
      [
        ("type", `String "oas_telemetry_sample");
        ("payload", sample_entry_to_yojson entry);
        ("provider_id", `String public_runtime_provider_label);
        ("model_id", `String public_runtime_model_label);
        ("ts_unix", `Float recorded_at);
      ]
  in
  try !broadcast_hook json
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Dashboard.warn "oas telemetry SSE broadcast failed: %s"
        (Printexc.to_string exn)

let record_with_time ~now (s : sample) =
  let s = normalize_sample s in
  let entry = (s, now) in
  with_lock (fun () ->
      let q =
        match Hashtbl.find_opt table s.provider_id with
        | Some q -> q
        | None ->
            let q = Queue.create () in
            Hashtbl.add table s.provider_id q;
            q
      in
      Queue.push (s, now) q;
      while Queue.length q > per_provider_cap do
        ignore (Queue.pop q)
      done);
  broadcast_sample_entry entry

let record (s : sample) = record_with_time ~now:(Unix.gettimeofday ()) s

let positive_ms = function
  | Some ms when ms > 0.0 && Float.is_finite ms -> Some ms
  | _ -> None

let ttfb_from_telemetry (telemetry : Agent_sdk.Types.inference_telemetry) =
  match positive_ms telemetry.ttfrc_ms with
  | Some _ as value -> value
  | None -> (
      match positive_ms telemetry.prefill_ms with
      | Some _ as value -> value
      | None -> (
          match telemetry.timings with
          | Some { prompt_ms; _ } -> positive_ms prompt_ms
          | None -> None))

let duration_from_response ?total_duration_ms
    (response : Agent_sdk.Types.api_response) =
  let duration_from_telemetry (telemetry : Agent_sdk.Types.inference_telemetry) =
    let decode_ms =
      match telemetry.timings with
      | Some { predicted_ms; _ } -> positive_ms predicted_ms
      | None -> None
    in
    match ttfb_from_telemetry telemetry, decode_ms with
    | Some ttfb_ms, Some decode_ms -> ttfb_ms +. decode_ms
    | Some ttfb_ms, None -> ttfb_ms
    | None, Some decode_ms -> decode_ms
    | None, None -> default_duration_ms
  in
  match total_duration_ms, response.telemetry with
  | Some ms, _ when ms > 0.0 -> ms
  | _, Some telemetry -> (
      match telemetry.request_latency_ms with
      | Some ms when ms > 0 -> Float.of_int ms
      | _ -> duration_from_telemetry telemetry)
  | _ -> default_ttfb_ms

let ttfb_from_response (response : Agent_sdk.Types.api_response) =
  match response.telemetry with
  | Some telemetry -> Option.value ~default:default_ttfb_ms (ttfb_from_telemetry telemetry)
  | _ -> default_ttfb_ms

let cache_hit_from_response ~(usage : Agent_sdk.Types.api_usage option)
    (response : Agent_sdk.Types.api_response) =
  let usage_cache_hit =
    Option.map
      (fun (usage : Agent_sdk.Types.api_usage) ->
        usage.cache_read_input_tokens > 0)
      usage
  in
  let telemetry_cache_hit =
    match response.telemetry with
    | Some { timings = Some { cache_n = Some n; _ }; _ } -> Some (n > 0)
    | _ -> None
  in
  match usage_cache_hit, telemetry_cache_hit with
  | Some true, _ | _, Some true -> Some true
  | Some false, _ | _, Some false -> Some false
  | None, None -> None

let throughput_from_response ~(usage : Agent_sdk.Types.api_usage option)
    ~ttfb_ms
    ~total_duration_ms (response : Agent_sdk.Types.api_response) =
  match response.telemetry with
  | Some { timings = Some { predicted_per_second = Some v; _ }; _ }
    when v > 0.0 -> Some v
  | _ ->
      Option.map
        (fun (usage : Agent_sdk.Types.api_usage) ->
          if usage.output_tokens <= 0 then 0.0
          else
            let decode_ms = Float.max 1.0 (total_duration_ms -. ttfb_ms) in
            Float.of_int usage.output_tokens /. (decode_ms /. 1000.0))
        usage

let sample_of_response ~provider_id:_ ~model_id:_ ?total_duration_ms
    ?(serialization_ms = 0.0) ?(retry_count = 0) ~status
    (response : Agent_sdk.Types.api_response) =
  let usage = response.usage in
  let total_duration_ms =
    duration_from_response ?total_duration_ms response
  in
  let ttfb_ms = ttfb_from_response response in
  {
    provider_id = public_runtime_provider_label;
    model_id = public_runtime_model_label;
    ttfb_ms;
    total_duration_ms;
    serialization_ms;
    usage_reported = Option.is_some usage;
    input_tokens =
      Option.map
        (fun (usage : Agent_sdk.Types.api_usage) -> usage.input_tokens)
        usage;
    output_tokens =
      Option.map
        (fun (usage : Agent_sdk.Types.api_usage) -> usage.output_tokens)
        usage;
    throughput_tokens_per_s =
      throughput_from_response ~usage ~ttfb_ms ~total_duration_ms response;
    cost_usd =
      Option.bind usage (fun (usage : Agent_sdk.Types.api_usage) ->
          usage.cost_usd);
    cache_hit = cache_hit_from_response ~usage response;
    status;
    retry_count;
  }

let record_response ~provider_id ~model_id ?total_duration_ms ?serialization_ms
    ?retry_count ~status response =
  record
    (sample_of_response ~provider_id ~model_id ?total_duration_ms
       ?serialization_ms ?retry_count ~status response)

let snapshot_provider _provider =
  let provider = public_runtime_provider_label in
  with_lock (fun () ->
      match Hashtbl.find_opt table provider with
      | None -> []
      | Some q -> Queue.fold (fun acc x -> x :: acc) [] q)

let snapshot_all () =
  with_lock (fun () ->
      Hashtbl.fold
        (fun _ q acc -> Queue.fold (fun a x -> x :: a) acc q)
        table [])

let take_first = List.take

let recent ?provider ?(limit = 50) () =
  let xs =
    match provider with
    | Some p -> snapshot_provider p
    | None -> snapshot_all ()
  in
  let sorted =
    List.sort (fun (_, t1) (_, t2) -> Float.compare t2 t1) xs
  in
  take_first limit sorted

type summary = {
  sample_count : int;
  ttfb_p50_ms : float;
  ttfb_p95_ms : float;
  total_duration_p50_ms : float;
  total_duration_p95_ms : float;
  total_duration_p99_ms : float;
  cache_hit_ratio : float;
  total_cost_usd : float;
  error_ratio : float;
  cancelled_count : int;
}

let zero_summary () =
  {
    sample_count = 0;
    ttfb_p50_ms = 0.0;
    ttfb_p95_ms = 0.0;
    total_duration_p50_ms = 0.0;
    total_duration_p95_ms = 0.0;
    total_duration_p99_ms = 0.0;
    cache_hit_ratio = 0.0;
    total_cost_usd = 0.0;
    error_ratio = 0.0;
    cancelled_count = 0;
  }

(* Nearest-rank percentile (no interpolation) keeps the dashboard
   deterministic with very small windows: for [n] sorted samples and
   probability [p], idx = ceil(p*n) - 1, clamped to [0, n-1]. Matches
   the .mli contract documented for callers. *)
let percentile (sorted : float array) (p : float) =
  let n = Array.length sorted in
  if n = 0 then 0.0
  else
    let idx = int_of_float (Float.ceil (p *. float_of_int n)) - 1 in
    let idx = max 0 (min idx (n - 1)) in
    sorted.(idx)

let summary ?provider ?limit () =
  let xs = recent ?provider ?limit () in
  match xs with
  | [] -> zero_summary ()
  | _ ->
      let n = List.length xs in
      let ttfbs =
        List.map (fun (s, _) -> s.ttfb_ms) xs |> Array.of_list
      in
      Array.sort Float.compare ttfbs;
      let durs =
        List.map (fun (s, _) -> s.total_duration_ms) xs |> Array.of_list
      in
      Array.sort Float.compare durs;
      let cache_values = List.filter_map (fun (s, _) -> s.cache_hit) xs in
      let cache_hits =
        List.fold_left
          (fun acc cache_hit -> if cache_hit then acc + 1 else acc)
          0 cache_values
      in
      let total_cost =
        List.fold_left
          (fun acc (s, _) ->
            match s.cost_usd with Some cost -> acc +. cost | None -> acc)
          0.0 xs
      in
      let errors =
        List.fold_left
          (fun acc (s, _) ->
            match s.status with
            | Error _ | Timeout -> acc + 1
            | Success | Cancelled _ -> acc)
          0 xs
      in
      let cancels =
        List.fold_left
          (fun acc (s, _) ->
            match s.status with
            | Cancelled _ -> acc + 1
            | Success | Error _ | Timeout -> acc)
          0 xs
      in
      {
        sample_count = n;
        ttfb_p50_ms = percentile ttfbs 0.50;
        ttfb_p95_ms = percentile ttfbs 0.95;
        total_duration_p50_ms = percentile durs 0.50;
        total_duration_p95_ms = percentile durs 0.95;
        total_duration_p99_ms = percentile durs 0.99;
        cache_hit_ratio =
          (match cache_values with
          | [] -> 0.0
          | values ->
              float_of_int cache_hits /. float_of_int (List.length values));
        total_cost_usd = total_cost;
        error_ratio = float_of_int errors /. float_of_int n;
        cancelled_count = cancels;
      }

let summary_to_yojson (s : summary) =
  `Assoc
    [
      ("sample_count", `Int s.sample_count);
      ("ttfb_p50_ms", `Float s.ttfb_p50_ms);
      ("ttfb_p95_ms", `Float s.ttfb_p95_ms);
      ("total_duration_p50_ms", `Float s.total_duration_p50_ms);
      ("total_duration_p95_ms", `Float s.total_duration_p95_ms);
      ("total_duration_p99_ms", `Float s.total_duration_p99_ms);
      ("cache_hit_ratio", `Float s.cache_hit_ratio);
      ("total_cost_usd", `Float s.total_cost_usd);
      ("error_ratio", `Float s.error_ratio);
      ("cancelled_count", `Int s.cancelled_count);
    ]

let recent_json ?provider ?limit () =
  let samples = recent ?provider ?limit () in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("dashboard_surface", `String "/api/v1/dashboard/oas/telemetry/recent");
      ("source", `String source_label);
      ("retention", retention_json);
      ("provider", provider_json provider);
      ( "limit", Json_util.int_opt_to_json limit );
      ("count", `Int (List.length samples));
      ("samples", `List (List.map sample_entry_to_yojson samples));
    ]

let summary_json ?provider ?limit () =
  let summary = summary ?provider ?limit () in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("dashboard_surface", `String "/api/v1/dashboard/oas/telemetry/summary");
      ("source", `String source_label);
      ("retention", retention_json);
      ("provider", provider_json provider);
      ( "limit", Json_util.int_opt_to_json limit );
      ("summary", summary_to_yojson summary);
    ]

let clear ?provider () =
  with_lock (fun () ->
      match normalize_provider_filter provider with
      | Some p ->
          Hashtbl.remove table p
      | None ->
          Hashtbl.reset table)
