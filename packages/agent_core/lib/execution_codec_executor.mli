(** Private typed codec service backed by one {!Execution_runtime.t}.

    Requests are closed and CPU-only. The runtime owns pool lifetime and raw
    submission; this module adds event-specific failure causality,
    cancellation checkpoints, and observations. *)

type t

type operation =
  | Encode_events
  | Decode_canonical_event
  | Compare_canonical_payload
[@@deriving show]

type cause

type failure =
  | Executor_unavailable of
      { operation : operation
      ; cause : cause
      }
  | Codec_raised of
      { operation : operation
      ; cause : cause
      }

type decode_failure =
  | Invalid_event of { detail : string }
  | Noncanonical_event

type operation_stats =
  { requested : int
  ; started : int
  ; completed : int
  ; job_failed : int
  ; worker_cancelled : int
  ; executor_failed : int
  ; caller_cancelled : int
  ; last_caller_domain : Domain.id option
  ; last_worker_domain : Domain.id option
  }

type stats =
  { encode_events : operation_stats
  ; decode_canonical_event : operation_stats
  ; compare_canonical_payload : operation_stats
  }

val of_runtime : Execution_runtime.t -> t

(** Encode one append batch. Cancellation is checked at every event boundary;
    no payload-size threshold or per-request pool is used. *)
val encode_events : t -> Execution_event.t list -> (string list, failure) result

(** Decode one durable payload. Store callers retain at most that raw payload
    while accumulating their required decoded output. *)
val decode_canonical_event
  :  t
  -> string
  -> ((Execution_event.t, decode_failure) result, failure) result

val compare_canonical_payload
  :  t
  -> expected:string
  -> actual:string
  -> (bool, failure) result

val failure_to_string : failure -> string
val pp_failure : Format.formatter -> failure -> unit
val show_failure : failure -> string

(** Read-only per-operation coherent snapshots. These observations never
    affect dispatch, cancellation, admission, or termination. *)
val stats : t -> stats
