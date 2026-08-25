(** Private typed ownership chain for one Agent execution journal.
    Construction requires an owned writer and never discovers paths or product
    policy. Abstract descendants cannot be moved across another scope. *)

type t
type turn
type provider_attempt
type scope_locator
type invocation_locator
type invocation

type invocation_authority = private
  { invocation : Tool_contract.Invocation.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

type settled_invocation = private
  { authority : invocation_authority
  ; result : Llm_provider.Types.content_block
  }

type tool_result = private
  { invocation : Tool_contract.Invocation.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; content : string
  ; outcome : Llm_provider.Types.tool_result_outcome
  }

type execution =
  | Executed of tool_result * Execution_journal.cursor * int
  | Replayed of tool_result

type invocation_progress =
  | Invocation_unattempted
  | Invocation_attempted_or_settled

type abort_reason =
  | Failed of Execution_event.failure
  | Cancelled of
      { reason : string option
      ; data : Yojson.Safe.t option
      }

type operator_repair_reason = Effect_outcome_unknown

type recovery_action =
  | Retire
  | Operator_repair_required of operator_repair_reason

type error =
  | Admission_failed of Execution_lane_writer.submit_error
  | Mutation_failed of Execution_lane_writer.ticket_error
  | Invalid_provider_attempt of string
  | Scope_unavailable of Execution_lane_writer.read_error
  | Run_not_found
  | Agent_identity_mismatch of
      { expected : string
      ; actual : string
      }
  | Invocation_locator_mismatch
  | Resume_topology_mismatch of string
  | Invalid_tool_result
  | Settlement_failed of Execution_tool_settlement.error

val error_to_string : error -> string
val start : writer:Execution_lane_writer.t -> agent_name:string -> (t, error) result
val scope_locator : t -> scope_locator
val scope_locator_run_id : scope_locator -> Execution_event.Run_id.t
val scope_locator_to_yojson : scope_locator -> Yojson.Safe.t
val scope_locator_of_yojson : Yojson.Safe.t -> (scope_locator, string) result

val resume
  :  writer:Execution_lane_writer.t
  -> agent_name:string
  -> scope_locator
  -> (t, error) result

(** Resume only a still-running root for public Agent execution. Terminal roots
    remain readable through {!resume} for audit/replay inspection. *)
val resume_running
  :  writer:Execution_lane_writer.t
  -> agent_name:string
  -> scope_locator
  -> (t, error) result

(** Total classification of a turn node found at a resume ordinal. [Settled] is a
    turn already [Closed Succeeded] under a still-[Running] root: an idempotent
    completed boundary (crash after {!close_turn} but before the root
    {!finish}). A [Closed Failed]/[Closed Cancelled] turn stays a
    [Resume_topology_mismatch] error (fail-closed on real corruption). *)
type turn_resume =
  | Resume_turn_absent
  | Resume_turn_open of turn
  | Resume_turn_settled of turn

(** Total classification of a provider attempt found under a resumed turn.
    [Settled] is a provider attempt already [Closed Succeeded] under a still-open
    turn (crash inside [close_success] after the provider close but before the
    turn close). See {!turn_resume} for the fail-closed contract. *)
type provider_resume =
  | Resume_provider_absent
  | Resume_provider_open of provider_attempt
  | Resume_provider_settled of provider_attempt

val open_turn : t -> ordinal:int -> (turn, error) result
val resume_turn : t -> ordinal:int -> (turn_resume, error) result

(** Classify the current turn from durable topology, without a caller-supplied
    ordinal. This is a recovery-only lookup; the turn identity is owned by the
    journal, never reconstructed from mutable agent state. [Resume_turn_open] is
    the single still-open turn (resume it); [Resume_turn_settled] is the
    highest-ordinal turn already [Closed Succeeded] under a still-[Running] root
    (an idempotent completed boundary to replay, not re-run); a [Closed
    Failed]/[Cancelled] frontier stays a [Resume_topology_mismatch] error;
    [Resume_turn_absent] is a genuinely fresh resume. *)
val resume_current_turn : t -> (turn_resume, error) result

val turn_ordinal : turn -> int

(** Materialize the exact binding selected for provider dispatch. *)
val open_provider_attempt
  :  turn
  -> ordinal:int
  -> Binding_identity.t
  -> (provider_attempt, error) result

val resume_provider_attempt : turn -> (provider_resume, error) result

(** Materialize the exact provider response once on its owning attempt. *)
val record_provider_response
  :  provider_attempt
  -> Llm_provider.Types.api_response
  -> (unit, error) result

(** Read the exact response authority required for restart recovery. *)
val provider_response
  :  provider_attempt
  -> (Llm_provider.Types.api_response, error) result

(** Atomically open an invocation and materialize the exact ToolUse input. *)
val open_invocation
  :  provider_attempt
  -> invocation:Tool_contract.Invocation.t
  -> tool_name:string
  -> input:Yojson.Safe.t
  -> (invocation, error) result

val find_invocation
  :  provider_attempt
  -> invocation:Tool_contract.Invocation.t
  -> tool_name:string
  -> input:Yojson.Safe.t
  -> (invocation option, error) result

(** Classify whether a durable invocation has crossed the effect-attempt
    boundary. An unattempted invocation carries no approval authority by
    itself: callers upgrading from an older admission protocol must run the
    current gate again before execution. *)
val invocation_progress : invocation -> (invocation_progress, error) result

(** Persist a model-visible blocked result without opening an effect attempt.
    Only an open invocation classified as [Invocation_unattempted] is accepted. *)
val settle_unattempted_invocation
  :  invocation
  -> content:string
  -> outcome:Llm_provider.Types.tool_result_outcome
  -> (unit, error) result

val provider_invocations_settled : provider_attempt -> (bool, error) result

(** Exact immutable invocation authority reconstructed only from persisted
    Tool_invocation nodes and their materialized ToolUse input. Results are
    ordered by planned index. *)
val provider_invocations : provider_attempt -> (invocation_authority list, error) result

(** Compare a restored ToolUse occurrence to exact persisted authority. This
    validates id, order, turn, name, input, schedule, and completion without
    consulting the current tool catalog. *)
val validate_invocation_authority
  :  invocation_authority
  -> turn:int
  -> planned_index:int
  -> tool_use_id:string
  -> tool_name:string
  -> input:Yojson.Safe.t
  -> (unit, error) result

(** Exact settled invocation/result pairs reconstructed from the journal and
    ordered by immutable planned index. Fails closed if any invocation lacks a
    durable result. *)
val provider_settled_invocations
  :  provider_attempt
  -> (settled_invocation list, error) result

(** Stable opaque coordinates for rebinding after the writer is reopened.
    The locator contains no copied Tool name, input, turn, or schedule; those
    values are reconstructed from the journal's exact durable topology. *)
val invocation_locator : invocation -> invocation_locator

val invocation_locator_to_yojson : invocation_locator -> Yojson.Safe.t
val invocation_locator_of_yojson : Yojson.Safe.t -> (invocation_locator, string) result
val rebind_invocation : t -> invocation_locator -> (invocation, error) result

(** Commit the attempt before the effect and atomically settle its result. *)
val execute
  :  invocation
  -> invoke:
       (start_child:(agent_name:string -> (t, error) result)
        -> tool_name:string
        -> input:Yojson.Safe.t
        -> string * Llm_provider.Types.tool_result_outcome)
  -> (execution, error) result

(** As {!execute}, but the effect returns a callback that runs only after its
    ToolResult is durably settled. Replayed results run neither phase. *)
val execute_phased
  :  invocation
  -> invoke:
       (start_child:(agent_name:string -> (t, error) result)
        -> tool_name:string
        -> input:Yojson.Safe.t
        -> (string * Llm_provider.Types.tool_result_outcome) * (unit -> unit))
  -> (execution, error) result

val close_provider_attempt
  :  provider_attempt
  -> Execution_event.terminal
  -> (unit, error) result

val close_turn : turn -> Execution_event.terminal -> (unit, error) result
val finish : t -> Execution_event.terminal -> (unit, error) result

(** Atomically terminate every open descendant and the run root. *)
val abort : t -> abort_reason -> (unit, error) result

(** Classify the terminal scope from its exact durable topology. An invocation
    with an admitted attempt and no settled ToolResult cannot be retried
    automatically because its external effect may already have happened. *)
val terminal_recovery_action : t -> (recovery_action, error) result
