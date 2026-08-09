(** Tool-capable research phase owned by the Librarian.

    Research receives the closed read/observation-only {!research_tool}
    authority. Its typed receipt is evidence for the existing tool-free exact
    Librarian finalizer; it never replaces that finalization authority. This
    module deliberately has no generic internal-role sum: a later role must
    prove and own its own production context and failure policy. *)

module Execution_id : sig
  type t

  val generate : unit -> t
  val to_string : t -> string
end

type raw_trace_sink_outcome =
  | Raw_trace_ready of Agent_sdk.Raw_trace.t
  | Raw_trace_degraded of Agent_sdk.Error.sdk_error

type research_tool =
  | Search_files
  | Read_file
  | Time_now
  | Context_status
  | Artifact_read
  | Memory_search
  | Library_search
  | Library_read
  | Surface_read
  | Web_search
  | Web_fetch
  | Fusion_status
  | Analyze_image
(** Closed, read/observation-only authority granted to the detached Librarian
    research phase. Operational/mutating Keeper tools are not representable. *)

(** Create a fresh retained-trace candidate for one Librarian research phase.
    The caller registers [Agent_sdk.Raw_trace.file_path] as a durable reachability
    root before dispatch. Sink failure prevents the research dispatch; the
    caller records that observation and may continue the exact finalizer. *)
val create_raw_trace_sink
  :  before_create:(string -> unit)
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> execution_id:Execution_id.t
  -> raw_trace_sink_outcome

type request =
  { execution_id : Execution_id.t
  ; runtime_id : string
  ; frozen_system_prompt : string
  ; frozen_prompt : string
  ; frozen_input : Yojson.Safe.t
  ; evidence_budget_bytes : int
  ; config : Workspace.config
  ; meta : Keeper_meta_contract.keeper_meta
  ; publication_recovery :
      Keeper_publication_recovery_availability.turn_context
  ; ctx_snapshot : Keeper_types.working_context
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; net : Eio_context.eio_net
  ; continuation_channel : Keeper_continuation_channel.t option
  ; raw_trace : Agent_sdk.Raw_trace.t option
  }

type tool_call_result =
  | Executed of Agent_sdk.Types.tool_result
  | Rejected_before_execution of string
  | Execution_failure_observed of string
  | Terminal_observation_missing

type tool_call =
  { invocation : Agent_sdk.Tool_contract.Invocation.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; started_at : float
  ; finished_at : float
  ; duration_ms : float
  ; result : tool_call_result
  }

type bounded_evidence =
  { text : string
  ; original_bytes : int
  ; retained_bytes : int
  ; truncated : bool
  }

type execution_outcome =
  | Research_completed of
      { evidence : bounded_evidence
      ; session_id : string
      ; turns : int
      ; stop_reason : Runtime_agent.stop_reason
      }
  | Research_failed of Agent_sdk.Error.sdk_error
  | Research_cancelled

type cleanup_outcome =
  | Cleanup_succeeded
  | Cleanup_failed of string
  | Cleanup_cancelled

type receipt =
  { execution_id : Execution_id.t
  ; runtime_id : string
  ; frozen_system_prompt : string
  ; frozen_prompt : string
  ; frozen_input : Yojson.Safe.t
  ; started_at : float
  ; finished_at : float
  ; duration_ms : float
  ; tool_names : string list
  ; tool_calls : tool_call list
  ; terminal_effect : Keeper_tools_oas.terminal_effect_state
  ; cleanup : cleanup_outcome
  ; outcome : execution_outcome
  ; trace_ref : Agent_sdk.Raw_trace.run_ref option
  }

val run : on_receipt:(receipt -> unit) -> request -> receipt
(** Run one research phase. [on_receipt] is called exactly once after cleanup
    and terminal observation freeze. Cancellation is re-raised only after the
    cancelled receipt has been delivered to this callback. *)

(** Secret-free long-lived registry projection. Frozen prompts/input, tool
    input/output, evidence text, and trace paths remain only in the retained
    raw-trace blob behind the operator route. *)
val registry_receipt_to_yojson : receipt -> Yojson.Safe.t

(** Bounded evidence projection consumed by the later exact-output phase. *)
val finalizer_evidence_to_yojson : receipt -> Yojson.Safe.t

module For_testing : sig
  val protect_with_cleanup
    :  cleanup:(unit -> unit)
    -> on_cleanup:(cleanup_outcome -> unit)
    -> (unit -> 'a)
    -> 'a

  val tool_names_for_request : request -> string list * cleanup_outcome

  val research_descriptor_contract : unit -> (string * bool option * string) list

  val invalid_request_gate_callback_count : request -> int
  (** Dispatch one schema-invalid occurrence through every research tool. No
      handler executes; each standard Keeper handler must still record exactly
      one Gate/result callback. *)
end
