(** How long pool submissions wait for a worker, and how long they then run,
    by {!Pool_lane.lane}. RFC-0204 §3.6.

    Counters are cumulative since the process started; two reads give a rate.
    Recording measures only. Nothing reads these values to decide where or
    whether work runs. *)

val record_wait : Pool_lane.lane -> Mtime.span -> unit
(** From the submit call to the worker entering the job. *)

val record_run : Pool_lane.lane -> Mtime.span -> unit
(** From the worker entering the job to the job returning or raising. *)

val record_abandoned : Pool_lane.lane -> Mtime.span -> unit
(** From the submit call to the caller's cancellation, for a submission no
    worker took. These are the waits [wait] cannot see: a deadline or a
    client that gave up ended them, so they are often the longest. *)

val to_json : unit -> Yojson.Safe.t
(** [{"bucket_upper_ms": [...], "read": {"wait": h, "run": h, "abandoned": h},
    "background": {...}}], where [h] is
    [{"count", "sum_ms", "max_ms", "buckets": [n0; ...; n_overflow]}]:
    bucket [i] counts spans at most [bucket_upper_ms.(i)] and above the bound
    before it; the last bucket counts spans above every bound.

    Fields are read one at a time while recording continues, so within one
    reply the buckets may sum to more than [count], and [sum_ms] may lag it. *)
