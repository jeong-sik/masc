(** See [Dashboard_oas_bridge.mli]. *)

let per_provider_cap = 200

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
  input_tokens : int;
  output_tokens : int;
  throughput_tokens_per_s : float;
  cost_usd : float;
  cache_hit : bool;
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

let sample_to_yojson (s : sample) =
  `Assoc
    [
      ("provider_id", `String s.provider_id);
      ("model_id", `String s.model_id);
      ("ttfb_ms", `Float s.ttfb_ms);
      ("total_duration_ms", `Float s.total_duration_ms);
      ("serialization_ms", `Float s.serialization_ms);
      ("input_tokens", `Int s.input_tokens);
      ("output_tokens", `Int s.output_tokens);
      ("throughput_tokens_per_s", `Float s.throughput_tokens_per_s);
      ("cost_usd", `Float s.cost_usd);
      ("cache_hit", `Bool s.cache_hit);
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
  | Some provider -> `String provider
  | None -> `Null

let broadcast_sample_entry entry =
  let sample, recorded_at = entry in
  let json =
    `Assoc
      [
        ("type", `String "oas_telemetry_sample");
        ("payload", sample_entry_to_yojson entry);
        ("provider_id", `String sample.provider_id);
        ("model_id", `String sample.model_id);
        ("ts_unix", `Float recorded_at);
      ]
  in
  try Sse.broadcast_to Sse.Observers json
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Dashboard.warn "oas telemetry SSE broadcast failed: %s"
        (Printexc.to_string exn)

let record_with_time ~now (s : sample) =
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

let duration_from_response ?total_duration_ms
    (response : Oas.Types.api_response) =
  match total_duration_ms, response.telemetry with
  | Some ms, _ when ms > 0.0 -> ms
  | _, Some telemetry when telemetry.request_latency_ms > 0 ->
      Float.of_int telemetry.request_latency_ms
  | _ -> 0.0

let ttfb_from_response (response : Oas.Types.api_response) =
  match response.telemetry with
  | Some { timings = Some { prompt_ms = Some ms; _ }; _ } when ms > 0.0 ->
      ms
  | _ -> 0.0

let cache_hit_from_response ~(usage : Oas.Types.api_usage)
    (response : Oas.Types.api_response) =
  usage.cache_read_input_tokens > 0
  ||
  match response.telemetry with
  | Some { timings = Some { cache_n = Some n; _ }; _ } -> n > 0
  | _ -> false

let throughput_from_response ~(usage : Oas.Types.api_usage) ~ttfb_ms
    ~total_duration_ms (response : Oas.Types.api_response) =
  match response.telemetry with
  | Some { timings = Some { predicted_per_second = Some v; _ }; _ }
    when v > 0.0 -> v
  | _ ->
      if usage.output_tokens <= 0 then 0.0
      else
        let decode_ms = Float.max 1.0 (total_duration_ms -. ttfb_ms) in
        Float.of_int usage.output_tokens /. (decode_ms /. 1000.0)

let sample_of_response ~provider_id ~model_id ?total_duration_ms
    ?(serialization_ms = 0.0) ?(retry_count = 0) ~status
    (response : Oas.Types.api_response) =
  let usage = Oas_response.usage_or_zero response in
  let total_duration_ms =
    duration_from_response ?total_duration_ms response
  in
  let ttfb_ms = ttfb_from_response response in
  {
    provider_id;
    model_id;
    ttfb_ms;
    total_duration_ms;
    serialization_ms;
    input_tokens = usage.input_tokens;
    output_tokens = usage.output_tokens;
    throughput_tokens_per_s =
      throughput_from_response ~usage ~ttfb_ms ~total_duration_ms response;
    cost_usd = Option.value ~default:0.0 usage.cost_usd;
    cache_hit = cache_hit_from_response ~usage response;
    status;
    retry_count;
  }

let record_response ~provider_id ~model_id ?total_duration_ms ?serialization_ms
    ?retry_count ~status response =
  record
    (sample_of_response ~provider_id ~model_id ?total_duration_ms
       ?serialization_ms ?retry_count ~status response)

let snapshot_provider provider =
  with_lock (fun () ->
      match Hashtbl.find_opt table provider with
      | None -> []
      | Some q -> Queue.fold (fun acc x -> x :: acc) [] q)

let snapshot_all () =
  with_lock (fun () ->
      Hashtbl.fold
        (fun _ q acc -> Queue.fold (fun a x -> x :: a) acc q)
        table [])

let take_first n xs =
  let rec aux n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: rest -> aux (n - 1) (x :: acc) rest
  in
  aux n [] xs

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

let zero_summary =
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
  | [] -> zero_summary
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
      let cache_hits =
        List.fold_left
          (fun acc (s, _) -> if s.cache_hit then acc + 1 else acc)
          0 xs
      in
      let total_cost =
        List.fold_left (fun acc (s, _) -> acc +. s.cost_usd) 0.0 xs
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
            match s.status with Cancelled _ -> acc + 1 | _ -> acc)
          0 xs
      in
      {
        sample_count = n;
        ttfb_p50_ms = percentile ttfbs 0.50;
        ttfb_p95_ms = percentile ttfbs 0.95;
        total_duration_p50_ms = percentile durs 0.50;
        total_duration_p95_ms = percentile durs 0.95;
        total_duration_p99_ms = percentile durs 0.99;
        cache_hit_ratio = float_of_int cache_hits /. float_of_int n;
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
      ("provider", provider_json provider);
      ( "limit",
        match limit with
        | Some limit -> `Int limit
        | None -> `Null );
      ("count", `Int (List.length samples));
      ("samples", `List (List.map sample_entry_to_yojson samples));
    ]

let summary_json ?provider ?limit () =
  let summary = summary ?provider ?limit () in
  `Assoc
    [
      ("provider", provider_json provider);
      ( "limit",
        match limit with
        | Some limit -> `Int limit
        | None -> `Null );
      ("summary", summary_to_yojson summary);
    ]

let clear ?provider () =
  with_lock (fun () ->
      match provider with
      | Some p -> Hashtbl.remove table p
      | None -> Hashtbl.reset table)
