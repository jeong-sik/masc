(** Direct evidence extraction from agent runs.

    Materializes worker run data, proof bundles, and conformance
    reports from a live {!Agent.t} and its {!Raw_trace.t}.

    @stability Evolving
    @since 0.93.1 *)

type options =
  { session_root : string option
  ; session_id : string
  ; goal : string
  ; title : string option
  ; tag : string option
  ; worker_id : string option
  ; runtime_actor : string option
  ; role : string option
  ; aliases : string list
  ; requested_provider : string option
  ; requested_model : string option
  ; requested_policy : string option
  ; workdir : string option
  }

type raw_details =
  { validated : bool
  ; tool_names : string list
  ; final_text : string option
  ; stop_reason : string option
  ; error : string option
  ; paired_tool_result_count : int
  ; has_file_write : bool
  ; verification_pass_after_file_write : bool
  ; failure_reason : string option
  }

(** Extract a single worker run from an agent and its trace. *)
val get_worker_run
  :  agent:Agent.t
  -> raw_trace:Raw_trace.t
  -> options:options
  -> unit
  -> (Sessions.worker_run, Error.sdk_error) result

(** Persist evidence and return a proof bundle. *)
val get_proof_bundle
  :  agent:Agent.t
  -> raw_trace:Raw_trace.t
  -> options:options
  -> unit
  -> (Sessions.proof_bundle, Error.sdk_error) result

(** Generate a conformance report from an agent run. *)
val get_conformance
  :  agent:Agent.t
  -> raw_trace:Raw_trace.t
  -> options:options
  -> unit
  -> (Conformance.report, Error.sdk_error) result

(** Alias for {!get_conformance}. *)
val run_conformance
  :  agent:Agent.t
  -> raw_trace:Raw_trace.t
  -> options:options
  -> unit
  -> (Conformance.report, Error.sdk_error) result

(** Persist evidence to disk and return a proof bundle.
    Used by examples and external tools. *)
val persist
  :  agent:Agent.t
  -> raw_trace:Raw_trace.t
  -> options:options
  -> unit
  -> (Sessions.proof_bundle, Error.sdk_error) result
