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
  usage_reported : bool;
  input_tokens : int option;
  output_tokens : int option;
  throughput_tokens_per_s : float option;
  cost_usd : float option;
  cache_hit : bool option;
  status : status;
  retry_count : int;
}

type provider_error_count = {
  provider_id : string;
  cascade_name : string;
  kind : string;
  capacity_scope : string;
  count : int;
}

(* Guards [table]. Critical sections are short — queue push, fold, or clear.
   Stdlib.Mutex is chosen over Eio.Mutex because record/read may be called
   from different domains, and the section never yields to Eio. Same
   rationale as Dashboard_attribution. *)
let mu = Mutex.create ()

(* Per-provider FIFO. Head = oldest, tail = newest. *)
let table : (string, (sample * float) Queue.t) Hashtbl.t =
  Hashtbl.create 8

let provider_error_table : (string * string * string * string, int) Hashtbl.t =
  Hashtbl.create 16

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

let int_opt_to_yojson = function Some value -> `Int value | None -> `Null
let float_opt_to_yojson = function Some value -> `Float value | None -> `Null
let bool_opt_to_yojson = function Some value -> `Bool value | None -> `Null

let sample_to_yojson (s : sample) =
  `Assoc
    [
      ("provider_id", `String s.provider_id);
      ("model_id", `String s.model_id);
      ("ttfb_ms", `Float s.ttfb_ms);
      ("total_duration_ms", `Float s.total_duration_ms);
      ("serialization_ms", `Float s.serialization_ms);
      ("usage_reported", `Bool s.usage_reported);
      ("input_tokens", int_opt_to_yojson s.input_tokens);
      ("output_tokens", int_opt_to_yojson s.output_tokens);
      ( "throughput_tokens_per_s",
        float_opt_to_yojson s.throughput_tokens_per_s );
      ("cost_usd", float_opt_to_yojson s.cost_usd);
      ("cache_hit", bool_opt_to_yojson s.cache_hit);
      ("status", status_to_yojson s.status);
      ("retry_count", `Int s.retry_count);
    ]

let sample_entry_to_yojson (s, recorded_at) =
  `Assoc
    [
      ("sample", sample_to_yojson s);
      ("recorded_at", `Float recorded_at);
    ]

let provider_error_count_to_yojson (c : provider_error_count) =
  `Assoc
    [
      ("provider_id", `String c.provider_id);
      ("cascade_name", `String c.cascade_name);
      ("kind", `String c.kind);
      ("capacity_scope", `String c.capacity_scope);
      ("count", `Int c.count);
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
    (response : Agent_sdk.Types.api_response) =
  let positive = function Some ms when ms > 0.0 -> Some ms | _ -> None in
  let duration_from_timings = function
    | Some (timings : Agent_sdk.Types.inference_timings) -> (
        match (positive timings.prompt_ms, positive timings.predicted_ms) with
        | Some prompt_ms, Some predicted_ms -> prompt_ms +. predicted_ms
        | Some prompt_ms, None -> prompt_ms
        | None, Some predicted_ms -> predicted_ms
        | None, None -> 0.0)
    | None -> 0.0
  in
  match total_duration_ms, response.telemetry with
  | Some ms, _ when ms > 0.0 -> ms
  | _, Some telemetry -> duration_from_timings telemetry.timings
      |> fun timings_ms ->
      (match telemetry.request_latency_ms with
       | Some ms when ms > 0 -> Float.of_int ms
       | _ -> timings_ms)
  | _ -> 0.0

let ttfb_from_response (response : Agent_sdk.Types.api_response) =
  match response.telemetry with
  | Some { timings = Some { prompt_ms = Some ms; _ }; _ } when ms > 0.0 ->
      ms
  | _ -> 0.0

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

let sample_of_response ~provider_id ~model_id ?total_duration_ms
    ?(serialization_ms = 0.0) ?(retry_count = 0) ~status
    (response : Agent_sdk.Types.api_response) =
  let usage = Oas_response.usage response in
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

let provider_error_capacity_scope_label = function
  | Provider_error.CapacityExhausted { scope; _ } ->
      Provider_error.scope_to_string scope
  | Provider_error.RateLimit _
  | Provider_error.AuthError _
  | Provider_error.ServerError _
  | Provider_error.InvalidRequest _ ->
      "none"

let record_provider_error ~cascade_name ~provider_id error =
  let kind = Provider_error.to_error_kind error in
  let capacity_scope = provider_error_capacity_scope_label error in
  let key = (provider_id, cascade_name, kind, capacity_scope) in
  with_lock (fun () ->
      let count =
        match Hashtbl.find_opt provider_error_table key with
        | Some count -> count
        | None -> 0
      in
      Hashtbl.replace provider_error_table key (count + 1))

let compare_provider_error_count a b =
  match Int.compare b.count a.count with
  | 0 -> (
      match String.compare a.provider_id b.provider_id with
      | 0 -> (
          match String.compare a.cascade_name b.cascade_name with
          | 0 -> (
              match String.compare a.kind b.kind with
              | 0 -> String.compare a.capacity_scope b.capacity_scope
              | c -> c)
          | c -> c)
      | c -> c)
  | c -> c

let provider_error_counts ?provider () =
  let counts =
    with_lock (fun () ->
        Hashtbl.fold
          (fun (provider_id, cascade_name, kind, capacity_scope) count acc ->
            match provider with
            | Some provider when not (String.equal provider provider_id) -> acc
            | _ ->
                {
                  provider_id;
                  cascade_name;
                  kind;
                  capacity_scope;
                  count;
                }
                :: acc)
          provider_error_table [])
  in
  List.sort compare_provider_error_count counts

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
  provider_error_counts : provider_error_count list;
}

let zero_summary provider_error_counts =
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
    provider_error_counts;
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
  let provider_error_counts = provider_error_counts ?provider () in
  match xs with
  | [] -> zero_summary provider_error_counts
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
        cache_hit_ratio =
          (match cache_values with
          | [] -> 0.0
          | values ->
              float_of_int cache_hits /. float_of_int (List.length values));
        total_cost_usd = total_cost;
        error_ratio = float_of_int errors /. float_of_int n;
        cancelled_count = cancels;
        provider_error_counts;
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
      ( "provider_error_counts",
        `List (List.map provider_error_count_to_yojson s.provider_error_counts)
      )
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
      | Some p ->
          Hashtbl.remove table p;
          let keys =
            Hashtbl.fold
              (fun (provider_id, cascade_name, kind, capacity_scope) _ acc ->
                if String.equal provider_id p then
                  (provider_id, cascade_name, kind, capacity_scope) :: acc
                else acc)
              provider_error_table []
          in
          List.iter (Hashtbl.remove provider_error_table) keys
      | None ->
          Hashtbl.reset table;
          Hashtbl.reset provider_error_table)
