type gc_snapshot = Scheduler_lag.gc_snapshot =
  { minor_collections : int
  ; major_collections : int
  ; compactions : int
  ; forced_major_collections : int
  ; heap_words : int
  ; top_heap_words : int
  ; minor_words : float
  ; major_words : float
  ; promoted_words : float
  }

type lag_percentiles = Scheduler_lag.lag_percentiles =
  { sample_count : int
  ; p50_ms : float
  ; p95_ms : float
  ; p99_ms : float
  ; max_ms : float
  ; over_50ms_count : int
  ; over_200ms_count : int
  }

type snapshot = Scheduler_lag.snapshot =
  { lag : lag_percentiles
  ; gc : gc_snapshot
  }

type t = Scheduler_lag.t

let default_capacity = Scheduler_lag.default_window
let default_interval_s = 0.020

let create ?(capacity = default_capacity) () =
  if capacity <= 0
  then invalid_arg "Server_scheduler_probe.create: capacity must be positive";
  Scheduler_lag.create ~interval_s:default_interval_s ~window:capacity ()
;;

let global = Scheduler_lag.global
let default = global
let record_lag_ms = Scheduler_lag.record_lag_ms
let capture_gc = Scheduler_lag.capture_gc
let compute_lag_percentiles = Scheduler_lag.compute_lag_percentiles
let snapshot = Scheduler_lag.snapshot
let gc_snapshot_to_yojson = Scheduler_lag.gc_snapshot_to_yojson
let lag_percentiles_to_yojson = Scheduler_lag.lag_percentiles_to_yojson
let snapshot_to_yojson = Scheduler_lag.snapshot_to_yojson
let run_probe_loop = Scheduler_lag.run_probe_loop
