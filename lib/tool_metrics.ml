module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

module StringMap = Map.Make (String)

(** Per-tool timing metrics *)

type tool_stats = {
  tool_name : string;
  call_count : int;
  success_count : int;
  failure_count : int;
  p50_ms : float;
  p95_ms : float;
  p99_ms : float;
  mean_ms : float;
}

(** Per-tool accumulator: we store all durations for percentile calc.
    Immutable record — updated by creating a new value and storing it
    in the StringMap ref under the lock. *)
type accumulator = {
  successes : int;
  failures : int;
  durations : float list;  (* newest first *)
}

(** [metrics] is updated from the tool_dispatch post-hook which runs on
    whichever fiber executed the tool.  Concurrent tool calls would
    otherwise race on the StringMap ref swap and on the accumulator
    update.  Stdlib.Mutex because HTTP stats endpoints may run on a
    different domain. *)
let metrics : accumulator StringMap.t ref = ref StringMap.empty
let metrics_mu = Stdlib.Mutex.create ()

let with_lock f =
  Stdlib.Mutex.lock metrics_mu;
  Stdlib.Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock metrics_mu)
    f

let record (result : Tool_result.t) =
  with_lock (fun () ->
    let acc = match StringMap.find_opt result.tool_name !metrics with
      | Some a -> a
      | None -> { successes = 0; failures = 0; durations = [] }
    in
    let acc =
      if result.success
      then { acc with successes = acc.successes + 1 }
      else { acc with failures = acc.failures + 1 }
    in
    let acc = { acc with durations = result.duration_ms :: acc.durations } in
    metrics := StringMap.add result.tool_name acc !metrics)

let percentile sorted_arr p =
  let n = Array.length sorted_arr in
  if n = 0 then 0.0
  else
    let idx = Float.to_int (Float.round (Stdlib.Float.of_int (n - 1) *. p)) in
    let idx = max 0 (min (n - 1) idx) in
    sorted_arr.(idx)

let compute_stats tool_name acc =
  let arr = Array.of_list acc.durations in
  Array.sort Float.compare arr;
  let n = Array.length arr in
  let mean = if n = 0 then 0.0
    else Array.fold_left ( +. ) 0.0 arr /. Stdlib.Float.of_int n in
  { tool_name
  ; call_count = acc.successes + acc.failures
  ; success_count = acc.successes
  ; failure_count = acc.failures
  ; p50_ms = percentile arr 0.50
  ; p95_ms = percentile arr 0.95
  ; p99_ms = percentile arr 0.99
  ; mean_ms = mean
  }

let stats_for tool_name =
  with_lock (fun () ->
    match StringMap.find_opt tool_name !metrics with
    | Some acc -> Some (compute_stats tool_name acc)
    | None -> None)

let all_stats () =
  let all =
    with_lock (fun () ->
      StringMap.fold (fun name acc lst ->
        compute_stats name acc :: lst
      ) !metrics [])
  in
  List.sort (fun a b -> Int.compare b.call_count a.call_count) all

let to_json s =
  `Assoc
    [ ("tool_name", `String s.tool_name)
    ; ("call_count", `Int s.call_count)
    ; ("success_count", `Int s.success_count)
    ; ("failure_count", `Int s.failure_count)
    ; ("p50_ms", `Float s.p50_ms)
    ; ("p95_ms", `Float s.p95_ms)
    ; ("p99_ms", `Float s.p99_ms)
    ; ("mean_ms", `Float s.mean_ms)
    ]

let all_to_json () =
  `List (List.map to_json (all_stats ()))

let clear () = with_lock (fun () -> metrics := StringMap.empty)

let install () =
  Tool_dispatch.register_post_hook (fun result ->
    record result;
    result)