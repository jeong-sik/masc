(* Resolution for reading a wait, not a threshold: the boundaries are where a
   reader of /health tells "a worker took it at once" (≤ 1 ms) from "it sat
   behind other jobs" and from the TUI's 10 s client timeout. *)
let bucket_upper_ms = [ 1.; 2.; 5.; 10.; 20.; 50.; 100.; 200.; 500.; 1000.; 2000.; 5000.; 10000. ]

let bucket_upper_ns =
  Array.of_list (List.map (fun ms -> Int64.of_float (ms *. 1e6)) bucket_upper_ms)
;;

type histogram =
  { buckets : int Atomic.t array
  ; count : int Atomic.t
  ; sum_ns : int Atomic.t
  ; max_ns : int Atomic.t
  }

let histogram () =
  { buckets = Array.init (Array.length bucket_upper_ns + 1) (fun _ -> Atomic.make 0)
  ; count = Atomic.make 0
  ; sum_ns = Atomic.make 0
  ; max_ns = Atomic.make 0
  }
;;

(* RFC-0474 L4a. Eio's executor counts a job's weight in millionths and a
   worker admits jobs until the weights it runs reach one million, whether
   those jobs use the CPU or wait. A lane holds as many workers' worth of
   weight as this sum divided by [units_per_worker]. *)
let units_per_worker = 1_000_000
let weight_units weight = Float.to_int (weight *. float units_per_worker)

(* Waits by the workers' worth of weight the lane's running jobs held when
   the job was submitted: 0, 1, 2, and 3 or more. The read pool has two
   workers, so its waits at 2 or more arrived when every worker could be
   full. *)
let in_flight_bucket_count = 4

(* The pools' own weights are 0.05 for I/O and 1.0 for CPU work; this splits
   the two. *)
let declared_cpu_weight = 0.5

(* RFC-0474 L4c. Each submission names the work (its call site's
   [__FUNCTION__], or the store a [Dated_jsonl] read reads), so a lane's wait
   and run time can be told apart by who submitted it. *)
type named =
  { named_count : int Atomic.t
  ; named_wait_sum_ns : int Atomic.t
  ; named_wait_max_ns : int Atomic.t
  ; named_run_sum_ns : int Atomic.t
  ; named_run_max_ns : int Atomic.t
  ; named_abandoned : int Atomic.t
  }

let named () =
  { named_count = Atomic.make 0
  ; named_wait_sum_ns = Atomic.make 0
  ; named_wait_max_ns = Atomic.make 0
  ; named_run_sum_ns = Atomic.make 0
  ; named_run_max_ns = Atomic.make 0
  ; named_abandoned = Atomic.make 0
  }
;;

module Names = Map.Make (String)

type lane_histograms =
  { wait : histogram
  ; run : histogram
  ; abandoned : histogram
  ; wait_by_in_flight : histogram array
  ; run_declared_io : histogram
  ; run_declared_cpu : histogram
  ; in_flight_units : int Atomic.t
  ; by_name : named Names.t Atomic.t
  }

let lane_histograms () =
  { wait = histogram ()
  ; run = histogram ()
  ; abandoned = histogram ()
  ; wait_by_in_flight = Array.init in_flight_bucket_count (fun _ -> histogram ())
  ; run_declared_io = histogram ()
  ; run_declared_cpu = histogram ()
  ; in_flight_units = Atomic.make 0
  ; by_name = Atomic.make Names.empty
  }
;;
let read = lane_histograms ()
let background = lane_histograms ()

let of_lane = function
  | Pool_lane.Read -> read
  | Pool_lane.Background -> background
;;

let bucket_index ns =
  let n = Array.length bucket_upper_ns in
  let rec find i = if i = n || Int64.compare ns bucket_upper_ns.(i) <= 0 then i else find (i + 1) in
  find 0
;;

let rec raise_max cell value =
  let seen = Atomic.get cell in
  if value > seen && not (Atomic.compare_and_set cell seen value) then raise_max cell value
;;

let record h span =
  let ns = Mtime.Span.to_uint64_ns span in
  Atomic.incr h.buckets.(bucket_index ns);
  Atomic.incr h.count;
  let ns = Int64.to_int ns in
  ignore (Atomic.fetch_and_add h.sum_ns ns);
  raise_max h.max_ns ns
;;

(* Names are a few hundred call sites, so after warm-up every lookup finds
   its entry and the map is only read. A name seen for the first time is added
   by compare-and-set; a writer that loses the race retries on the new map. *)
let rec named_of l name =
  let names = Atomic.get l.by_name in
  match Names.find_opt name names with
  | Some n -> n
  | None ->
    let n = named () in
    if Atomic.compare_and_set l.by_name names (Names.add name n names)
    then n
    else named_of l name
;;

let record_named ~sum ~max span =
  let ns = Int64.to_int (Mtime.Span.to_uint64_ns span) in
  ignore (Atomic.fetch_and_add sum ns);
  raise_max max ns
;;

let in_flight lane = Atomic.get (of_lane lane).in_flight_units
let enter lane ~weight = ignore (Atomic.fetch_and_add (of_lane lane).in_flight_units (weight_units weight))
let leave lane ~weight = ignore (Atomic.fetch_and_add (of_lane lane).in_flight_units (- weight_units weight))

let in_flight_bucket units =
  Int.min (in_flight_bucket_count - 1) (Int.max 0 (units / units_per_worker))
;;

let record_wait lane ~name ~in_flight span =
  let l = of_lane lane in
  record l.wait span;
  record l.wait_by_in_flight.(in_flight_bucket in_flight) span;
  let n = named_of l name in
  Atomic.incr n.named_count;
  record_named ~sum:n.named_wait_sum_ns ~max:n.named_wait_max_ns span
;;

let record_run lane ~name ~weight span =
  let l = of_lane lane in
  record l.run span;
  record (if weight < declared_cpu_weight then l.run_declared_io else l.run_declared_cpu) span;
  let n = named_of l name in
  record_named ~sum:n.named_run_sum_ns ~max:n.named_run_max_ns span
;;

let record_abandoned lane ~name span =
  let l = of_lane lane in
  record l.abandoned span;
  Atomic.incr (named_of l name).named_abandoned
;;

let ms_of_ns ns = float ns /. 1e6

let histogram_json h =
  `Assoc
    [ "count", `Int (Atomic.get h.count)
    ; "sum_ms", `Float (ms_of_ns (Atomic.get h.sum_ns))
    ; "max_ms", `Float (ms_of_ns (Atomic.get h.max_ns))
    ; "buckets", `List (Array.to_list (Array.map (fun c -> `Int (Atomic.get c)) h.buckets))
    ]
;;

(* /health is polled by every TUI and was about 13 KB on 2026-10-28; a row
   is about 180 bytes, so a lane reports the 20 names that ran longest in all
   rather than every name it has seen. Two reads of the list a measurement
   window apart still subtract for the names that matter. *)
let by_name_reported = 20

let by_name_json l =
  Names.bindings (Atomic.get l.by_name)
  |> List.map (fun (name, n) -> name, n, Atomic.get n.named_run_sum_ns)
  |> List.sort (fun (_, _, a) (_, _, b) -> Int.compare b a)
  |> List.filteri (fun i _ -> i < by_name_reported)
  |> List.map (fun (name, n, run_sum_ns) ->
    `Assoc
      [ "name", `String name
      ; "count", `Int (Atomic.get n.named_count)
      ; "wait_sum_ms", `Float (ms_of_ns (Atomic.get n.named_wait_sum_ns))
      ; "wait_max_ms", `Float (ms_of_ns (Atomic.get n.named_wait_max_ns))
      ; "run_sum_ms", `Float (ms_of_ns run_sum_ns)
      ; "run_max_ms", `Float (ms_of_ns (Atomic.get n.named_run_max_ns))
      ; "abandoned", `Int (Atomic.get n.named_abandoned)
      ])
;;

let lane_json l =
  `Assoc
    [ "wait", histogram_json l.wait
    ; "run", histogram_json l.run
    ; "abandoned", histogram_json l.abandoned
    ; "wait_by_in_flight_workers", `List (Array.to_list (Array.map histogram_json l.wait_by_in_flight))
    ; "run_declared_io", histogram_json l.run_declared_io
    ; "run_declared_cpu", histogram_json l.run_declared_cpu
    ; "in_flight_workers", `Float (float (Atomic.get l.in_flight_units) /. float units_per_worker)
    ; "by_name", `List (by_name_json l)
    ]

let to_json () =
  `Assoc
    [ "bucket_upper_ms", `List (List.map (fun ms -> `Float ms) bucket_upper_ms)
    ; Pool_lane.to_string Pool_lane.Read, lane_json read
    ; Pool_lane.to_string Pool_lane.Background, lane_json background
    ]
;;
