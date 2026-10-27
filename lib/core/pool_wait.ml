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

type lane_histograms =
  { wait : histogram
  ; run : histogram
  }

let read = { wait = histogram (); run = histogram () }
let background = { wait = histogram (); run = histogram () }

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

let record_wait lane span = record (of_lane lane).wait span
let record_run lane span = record (of_lane lane).run span

let ms_of_ns ns = float ns /. 1e6

let histogram_json h =
  `Assoc
    [ "count", `Int (Atomic.get h.count)
    ; "sum_ms", `Float (ms_of_ns (Atomic.get h.sum_ns))
    ; "max_ms", `Float (ms_of_ns (Atomic.get h.max_ns))
    ; "buckets", `List (Array.to_list (Array.map (fun c -> `Int (Atomic.get c)) h.buckets))
    ]
;;

let lane_json l = `Assoc [ "wait", histogram_json l.wait; "run", histogram_json l.run ]

let to_json () =
  `Assoc
    [ "bucket_upper_ms", `List (List.map (fun ms -> `Float ms) bucket_upper_ms)
    ; Pool_lane.to_string Pool_lane.Read, lane_json read
    ; Pool_lane.to_string Pool_lane.Background, lane_json background
    ]
;;
