module StringMap = Set_util.StringMap

(** Per-tool timing metrics *)

type tool_stats = {
  tool_name : string;
  call_count : int;
  success_count : int;
  deferred_count : int;
  failure_count : int;
  p50_ms : float;
  p95_ms : float;
  p99_ms : float;
  mean_ms : float;
}

type disposition =
  | Completed
  | Deferred
  | Failed

type sample = {
  tool_name : string;
  disposition : disposition;
  duration_ms : float;
}

(* Durations with duplicates: a stdlib float-keyed map keeps the count per
   exact duration, so the retained history never re-sorts and percentile
   selection just walks the ascending bindings once, counting samples.
   Selection is linear in the number of distinct durations; reads go through
   the all_stats cache, which one record invalidates. *)
module Duration_counts = Map.Make (Float)

type durations = { counts : int Duration_counts.t; total : int }

let durations_empty = { counts = Duration_counts.empty; total = 0 }

let durations_add value { counts; total } =
  { counts =
      Duration_counts.update value
        (function None -> Some 1 | Some n -> Some (n + 1))
        counts
  ; total = total + 1 }

let durations_cardinality { total; _ } = total

(* [index] is 0-based over samples in ascending duration order. *)
let durations_nth { counts; _ } index =
  let rec walk consumed seq =
    match seq () with
    | Seq.Nil -> None
    | Seq.Cons ((value, multiplicity), rest) ->
      let consumed = consumed + multiplicity in
      if index < consumed then Some value else walk consumed rest
  in
  walk 0 (Duration_counts.to_seq counts)

(** Per-tool accumulator. The duration multiset preserves duplicate values
    and supports exact percentile selection without sorting the complete
    retained history on every dashboard read. Immutable values are replaced
    in the StringMap under the lock. *)
type accumulator = {
  successes : int;
  deferred : int;
  failures : int;
  durations : durations;
  duration_sum : float;
}

(** [metrics] is updated from the tool dispatch observer which runs on
    whichever fiber executed the tool.  Concurrent tool calls would
    otherwise race on the StringMap ref swap and on the accumulator
    update.  Stdlib.Mutex because HTTP stats endpoints may run on a
    different domain. *)
let metrics : accumulator StringMap.t ref = ref StringMap.empty
let all_stats_cache : tool_stats list option ref = ref None
let metrics_mu = Stdlib.Mutex.create ()

let with_lock f = Stdlib.Mutex.protect metrics_mu f

type subscription = { callback : unit -> unit }
let subscriptions_mu = Stdlib.Mutex.create ()
let subscriptions : subscription list ref = ref []

let subscribe_written callback =
  let subscription = { callback } in
  Stdlib.Mutex.protect subscriptions_mu (fun () ->
    subscriptions := subscription :: !subscriptions);
  fun () -> Stdlib.Mutex.protect subscriptions_mu (fun () ->
    subscriptions := List.filter (fun current -> current != subscription) !subscriptions)

let announce_written () =
  let current = Stdlib.Mutex.protect subscriptions_mu (fun () -> !subscriptions) in
  List.iter (fun subscription ->
    match subscription.callback () with
    | () -> ()
    | exception exn ->
        (* Subscribers may only retain non-yielding metadata. A failed
           observer, including its cancellation, cannot undo this snapshot. *)
        (match Log.Metrics.warn "tool metrics subscriber failed: %s"
          (Printexc.exn_slot_name exn) with
         | () -> ()
         | exception _ -> ())) current

let add_sample metrics (sample : sample) =
  let acc =
    match StringMap.find_opt sample.tool_name metrics with
    | Some acc -> acc
    | None ->
      { successes = 0
      ; deferred = 0
      ; failures = 0
      ; durations = durations_empty
      ; duration_sum = 0.0
      }
  in
  let acc =
    match sample.disposition with
    | Completed -> { acc with successes = acc.successes + 1 }
    | Deferred -> { acc with deferred = acc.deferred + 1 }
    | Failed -> { acc with failures = acc.failures + 1 }
  in
  let acc =
    { acc with
      durations = durations_add sample.duration_ms acc.durations
    ; duration_sum = acc.duration_sum +. sample.duration_ms
    }
  in
  StringMap.add sample.tool_name acc metrics

let sample_of_result (result : Tool_result.result) =
  match result with
  | Tool_result.Completed output ->
    { tool_name = output.tool_name
    ; disposition = Completed
    ; duration_ms = output.duration_ms
    }
  | Tool_result.Deferred output ->
    { tool_name = output.tool_name
    ; disposition = Deferred
    ; duration_ms = output.duration_ms
    }
  | Tool_result.Failed failure ->
    { tool_name = failure.tool_name
    ; disposition = Failed
    ; duration_ms = failure.duration_ms
    }

let record (result : Tool_result.result) =
  let sample = sample_of_result result in
  with_lock (fun () ->
    metrics := add_sample !metrics sample;
    all_stats_cache := None);
  announce_written ()

let replace_samples produce =
  let replacement = ref StringMap.empty in
  let add sample = replacement := add_sample !replacement sample in
  match produce add with
  | Error _ as error -> error
  | Ok value ->
    with_lock (fun () ->
      metrics := !replacement;
      all_stats_cache := None);
    announce_written ();
    Ok value

let percentile durations p =
  let n = durations_cardinality durations in
  if n = 0 then 0.0
  else
    let idx = Float.to_int (Float.round (Stdlib.Float.of_int (n - 1) *. p)) in
    let idx = max 0 (min (n - 1) idx) in
    Option.value (durations_nth durations idx) ~default:0.0

let compute_stats tool_name acc =
  let n = durations_cardinality acc.durations in
  let mean =
    if n = 0 then 0.0 else acc.duration_sum /. Stdlib.Float.of_int n
  in
  { tool_name
  ; call_count = acc.successes + acc.deferred + acc.failures
  ; success_count = acc.successes
  ; deferred_count = acc.deferred
  ; failure_count = acc.failures
  ; p50_ms = percentile acc.durations 0.50
  ; p95_ms = percentile acc.durations 0.95
  ; p99_ms = percentile acc.durations 0.99
  ; mean_ms = mean
  }

let stats_for tool_name =
  with_lock (fun () ->
    match StringMap.find_opt tool_name !metrics with
    | Some acc -> Some (compute_stats tool_name acc)
    | None -> None)

let all_stats () =
  with_lock (fun () ->
    match !all_stats_cache with
    | Some snapshot -> snapshot
    | None ->
      let snapshot =
        StringMap.fold
          (fun name acc list -> compute_stats name acc :: list)
          !metrics
          []
        |> List.sort (fun a b -> Int.compare b.call_count a.call_count)
      in
      all_stats_cache := Some snapshot;
      snapshot)

let to_json (s : tool_stats) =
  `Assoc
    [ ("tool_name", `String s.tool_name)
    ; ("call_count", `Int s.call_count)
    ; ("success_count", `Int s.success_count)
    ; ("deferred_count", `Int s.deferred_count)
    ; ("failure_count", `Int s.failure_count)
    ; ("p50_ms", `Float s.p50_ms)
    ; ("p95_ms", `Float s.p95_ms)
    ; ("p99_ms", `Float s.p99_ms)
    ; ("mean_ms", `Float s.mean_ms)
    ]

let all_to_json () =
  `List (List.map to_json (all_stats ()))

let clear () =
  with_lock (fun () ->
    metrics := StringMap.empty;
    all_stats_cache := None);
  announce_written ()

(* Metrics are recorded only for handled dispatches. Other outcomes are
   counted by the dispatch telemetry path. *)
let install () =
  Tool_dispatch.register_dispatch_observer (fun outcome result ->
    match outcome, result with
    | Dispatch_outcome.Handled, Some r -> record r
    | (Dispatch_outcome.Handled, None) | (Dispatch_outcome.No_handler, _) -> ())
