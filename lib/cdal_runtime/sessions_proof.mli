(** Sessions proof assembly — worker-run construction and proof bundle.

    Transforms raw trace data and runtime participant metadata into
    structured {!Sessions_types.worker_run} records and assembles
    the complete {!Sessions_types.proof_bundle}.

    @stability Evolving
    @since 0.93.1 *)

open Sessions_types

(** {1 Participant lookup} *)

val participant_by_name : Runtime.session -> string -> Runtime.participant option

(** Resolve the effective provider for a participant,
    falling back to the session provider. *)
val resolved_provider_of_participant
  :  Runtime.session
  -> Runtime.participant option
  -> string option

(** Resolve the effective model for a participant,
    falling back to the session model. *)
val resolved_model_of_participant
  :  Runtime.session
  -> Runtime.participant option
  -> string option

(** Map participant state to worker status. *)
val worker_status_of_participant
  :  Runtime.participant option
  -> Sessions_types.worker_status

(** Compute the ordering timestamp for a worker run:
    [finished_at] > [last_progress_at] > [started_at]. *)
val worker_order_ts : Sessions_types.worker_run -> float option

(** {1 Worker run construction} *)

val worker_run_of_raw
  :  Runtime.session
  -> raw_trace_summary
  -> raw_trace_validation
  -> worker_run

val summary_only_worker_run : Runtime.session -> int -> Runtime.participant -> worker_run

(** {1 Worker run queries} *)

val sort_worker_runs : worker_run list -> worker_run list
val latest_worker_by : (worker_run -> bool) -> worker_run list -> worker_run option

val get_worker_runs
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (worker_run list, Error.sdk_error) result

val get_latest_worker_run
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (worker_run option, Error.sdk_error) result

val get_latest_accepted_worker_run
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (worker_run option, Error.sdk_error) result

val get_latest_ready_worker_run
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (worker_run option, Error.sdk_error) result

val get_latest_running_worker_run
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (worker_run option, Error.sdk_error) result

val get_latest_completed_worker_run
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (worker_run option, Error.sdk_error) result

val get_latest_failed_worker_run
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (worker_run option, Error.sdk_error) result

val get_latest_validated_worker_run
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (worker_run option, Error.sdk_error) result

(** {1 Evidence capabilities} *)

val unique_trace_capabilities : worker_run list -> trace_capability list

val evidence_capabilities_of_bundle
  :  raw_trace_runs:raw_trace_run list
  -> raw_trace_summaries:raw_trace_summary list
  -> raw_trace_validations:raw_trace_validation list
  -> evidence_capabilities

(** {1 Proof bundle} *)

val get_proof_bundle
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (proof_bundle, Error.sdk_error) result
