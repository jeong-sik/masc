(** Conformance checking for agent session proofs.

    Transforms a {!Sessions.proof_bundle} into a structured report
    with 17 conformance checks covering lifecycle, identity, tracing,
    and resolution.

    @stability Evolving
    @since 0.93.1 *)

type check =
  { code : string
  ; name : string
  ; passed : bool
  ; detail : string option
  }
[@@deriving yojson]

type summary =
  { session_id : string
  ; generated_at : float
  ; worker_run_count : int
  ; raw_trace_run_count : int
  ; validated_worker_run_count : int
  ; latest_accepted_worker_run_id : string option
  ; latest_ready_worker_run_id : string option
  ; latest_running_worker_run_id : string option
  ; latest_worker_run_id : string option
  ; latest_completed_worker_run_id : string option
  ; latest_worker_agent_name : string option
  ; latest_worker_status : string option
  ; latest_worker_role : string option
  ; latest_worker_aliases : string list
  ; latest_worker_validated : bool option
  ; latest_failed_worker_run_id : string option
  ; latest_failure_reason : string option
  ; latest_resolved_provider : string option
  ; latest_resolved_model : string option
  ; hook_event_count : int
  ; tool_catalog_count : int
  ; trace_capabilities : Sessions.trace_capability list
  }
[@@deriving yojson]

type report =
  { ok : bool
  ; summary : summary
  ; checks : check list
  }
[@@deriving yojson]

(** Generate a conformance report from a proof bundle. *)
val report : Sessions.proof_bundle -> report

(** Run conformance checks from a session on disk. *)
val run
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (report, Error.sdk_error) result
