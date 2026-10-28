(** How long pool submissions wait for a worker, and how long they then run,
    by {!Pool_lane.lane}. RFC-0204 §3.6.

    Counters are cumulative since the process started; two reads give a rate.
    Recording measures only. Nothing reads these values to decide where or
    whether work runs. *)

val in_flight : Pool_lane.lane -> int
(** The weight, in millionths as Eio's executor counts it, of the lane's jobs
    that entered a worker and have not returned. RFC-0474 L4a. *)

val enter : Pool_lane.lane -> weight:float -> unit
(** A job of [weight] entered a worker. *)

val leave : Pool_lane.lane -> weight:float -> unit
(** That job returned or raised. *)

val record_wait : Pool_lane.lane -> name:string -> in_flight:int -> Mtime.span -> unit
(** From the submit call to the worker entering the job; [in_flight] is
    {!in_flight} read at the submit call. The wait is also counted by the
    workers' worth of weight that was in flight: 0, 1, 2, and 3 or more, and
    under [name], the work's name (RFC-0474 L4c). *)

val record_run : Pool_lane.lane -> name:string -> weight:float -> Mtime.span -> unit
(** From the worker entering the job to the job returning or raising, also
    counted by the weight the job declared: below 0.5 (the pools' I/O jobs
    take 0.05) or 0.5 and above (CPU jobs and the 1.0 default), and under
    [name]. *)

val record_abandoned : Pool_lane.lane -> name:string -> Mtime.span -> unit
(** From the submit call to the caller's cancellation, for a submission no
    worker took. These are the waits [wait] cannot see: a deadline or a
    client that gave up ended them, so they are often the longest. [name]'s
    abandoned count goes up by one. *)

val to_json : unit -> Yojson.Safe.t
(** [{"bucket_upper_ms": [...], "read": {"wait": h, "run": h, "abandoned": h,
    "wait_by_in_flight_workers": [h0; h1; h2; h3], "run_declared_io": h,
    "run_declared_cpu": h, "in_flight_workers": w, "by_name": [n; ...]},
    "background": {...}}],
    where [w] is {!in_flight} in workers, [n] is
    [{"name", "count", "wait_sum_ms", "wait_max_ms", "run_sum_ms",
    "run_max_ms", "abandoned"}] for one work name — the 20 names with the
    longest run time in all, longest first — and [h] is
    [{"count", "sum_ms", "max_ms", "buckets": [n0; ...; n_overflow]}]:
    bucket [i] counts spans at most [bucket_upper_ms.(i)] and above the bound
    before it; the last bucket counts spans above every bound.

    Fields are read one at a time while recording continues, so within one
    reply the buckets may sum to more than [count], and [sum_ms] may lag it. *)
