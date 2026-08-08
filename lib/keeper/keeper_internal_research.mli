(** Tool-capable research phase shared by internal exact-output roles.

    Research receives the complete Keeper model-visible tool bundle. Its typed
    receipt is evidence for a later tool-free exact finalizer; it is never a
    replacement finalization authority. *)

type owner =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Compaction
  | Completion_authority

module Execution_id : sig
  type t

  val generate : unit -> t
  val to_string : t -> string
end

type raw_trace_sink_outcome =
  | Raw_trace_ready of Agent_sdk.Raw_trace.t
  | Raw_trace_degraded of Agent_sdk.Error.sdk_error

(** Create a fresh retained-trace candidate for one internal research phase.
    The caller registers [Agent_sdk.Raw_trace.file_path] as a durable reachability
    root before dispatch. Sink failure is observable but does not block the
    internal agent. *)
val create_raw_trace_sink
  :  before_create:(string -> unit)
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> execution_id:Execution_id.t
  -> raw_trace_sink_outcome

type request =
  { owner : owner
  ; execution_id : Execution_id.t
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

type cleanup_outcome =
  | Cleanup_succeeded
  | Cleanup_failed of string

type receipt =
  { owner : owner
  ; execution_id : Execution_id.t
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

val run : request -> receipt

(** Full receipt for durable/raw observation. Exact inputs and tool results are
    retained here; the finalizer projection below is deliberately bounded. *)
val receipt_to_yojson : receipt -> Yojson.Safe.t

(** Bounded evidence projection consumed by the later exact-output phase. *)
val finalizer_evidence_to_yojson : receipt -> Yojson.Safe.t

module For_testing : sig
  val protect_with_cleanup
    :  cleanup:(unit -> unit)
    -> on_cleanup:(cleanup_outcome -> unit)
    -> (unit -> 'a)
    -> 'a

  val tool_names_for_request : request -> string list * cleanup_outcome
end
