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

module Duration_tree = struct
  type t =
    | Empty
    | Node of
        { left : t
        ; value : float
        ; multiplicity : int
        ; right : t
        ; height : int
        ; cardinality : int
        }

  let empty = Empty

  let height = function
    | Empty -> 0
    | Node node -> node.height

  let cardinality = function
    | Empty -> 0
    | Node node -> node.cardinality

  let create left value multiplicity right =
    Node
      { left
      ; value
      ; multiplicity
      ; right
      ; height = Int.max (height left) (height right) + 1
      ; cardinality = cardinality left + multiplicity + cardinality right
      }

  let balance left value multiplicity right =
    let left_height = height left in
    let right_height = height right in
    if left_height > right_height + 2
    then
      match left with
      | Empty -> create left value multiplicity right
      | Node left_node ->
        if height left_node.left >= height left_node.right
        then
          create
            left_node.left
            left_node.value
            left_node.multiplicity
            (create left_node.right value multiplicity right)
        else
          (match left_node.right with
           | Empty -> create left value multiplicity right
           | Node pivot ->
             create
               (create
                  left_node.left
                  left_node.value
                  left_node.multiplicity
                  pivot.left)
               pivot.value
               pivot.multiplicity
               (create pivot.right value multiplicity right))
    else if right_height > left_height + 2
    then
      match right with
      | Empty -> create left value multiplicity right
      | Node right_node ->
        if height right_node.right >= height right_node.left
        then
          create
            (create left value multiplicity right_node.left)
            right_node.value
            right_node.multiplicity
            right_node.right
        else
          (match right_node.left with
           | Empty -> create left value multiplicity right
           | Node pivot ->
             create
               (create left value multiplicity pivot.left)
               pivot.value
               pivot.multiplicity
               (create
                  pivot.right
                  right_node.value
                  right_node.multiplicity
                  right_node.right))
    else create left value multiplicity right

  let rec add value = function
    | Empty -> create Empty value 1 Empty
    | Node node ->
      let comparison = Float.compare value node.value in
      if comparison = 0
      then
        (* Float.compare equates signed zeroes and NaN payloads. Keep the
           incoming key, as Map.update does when its count changes. *)
        create node.left value (node.multiplicity + 1) node.right
      else if comparison < 0
      then balance (add value node.left) node.value node.multiplicity node.right
      else balance node.left node.value node.multiplicity (add value node.right)

  let rec nth index = function
    | Empty -> None
    | Node node ->
      let left_size = cardinality node.left in
      if index < left_size
      then nth index node.left
      else if index < left_size + node.multiplicity
      then Some node.value
      else nth (index - left_size - node.multiplicity) node.right
end

(** Per-tool accumulator. The balanced duration tree stores each subtree's
    sample count, so exact percentile selection follows one logarithmic path.
    Immutable values are replaced in the StringMap under the lock. *)
type accumulator = {
  successes : int;
  deferred : int;
  failures : int;
  durations : Duration_tree.t;
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
  let duration_ms =
    if Float.is_finite sample.duration_ms && sample.duration_ms >= 0.0
    then sample.duration_ms
    else 0.0
  in
  let acc =
    match StringMap.find_opt sample.tool_name metrics with
    | Some acc -> acc
    | None ->
      { successes = 0
      ; deferred = 0
      ; failures = 0
      ; durations = Duration_tree.empty
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
      durations = Duration_tree.add duration_ms acc.durations
    ; duration_sum = acc.duration_sum +. duration_ms
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
  let n = Duration_tree.cardinality durations in
  if n = 0 then 0.0
  else
    let idx = Float.to_int (Float.round (Stdlib.Float.of_int (n - 1) *. p)) in
    let idx = max 0 (min (n - 1) idx) in
    Option.value (Duration_tree.nth idx durations) ~default:0.0

let compute_stats tool_name acc =
  let call_count = acc.successes + acc.deferred + acc.failures in
  let mean =
    if call_count = 0 then 0.0 else acc.duration_sum /. Stdlib.Float.of_int call_count
  in
  { tool_name
  ; call_count
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
