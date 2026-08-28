(** Exact-output producer for one validated Assembler request.

    AGENT_CORE owns frozen candidate admission, dispatch, and declared-order
    advancement. This module owns the Assembler prompt, semantic proposal
    validation, durable proposal publication, and exact-run observation. It
    never dispatches an ordinary Keeper Tool and never executes the accepted
    plan. *)

module Request = Keeper_assembler_request
module Proposal = Keeper_plan_proposal
module Store = Keeper_plan_proposal_store

type setup_error =
  | Prompt_projection_failed of Request.error
  | Prompt_render_failed of string
  | Registry_unavailable of Runtime_exact_output_registry.publication_error
  | Lane_unavailable of Runtime_exact_output_registry.lane_resolution_error
  | Lane_preference_unavailable of string
  | Invalid_candidate of
      { position : int
      ; slot_id : string
      }
  | Lane_resolved_without_candidates
  | Flow_snapshot_failed of
      { candidate_id : string
      ; first_position : int
      ; duplicate_position : int
      }
  | Flow_start_failed of string

type semantic_rejection =
  | Output_invalid of Request.output_error
  | Cannot_assemble
  | Proposal_invalid of Proposal.error

type exact_execution_failure =
  | Attempt_already_started of { evidence : string }
  | Attempt_start_failed of
      { slot_id : string
      ; detail : string
      ; evidence : string
      }
  | Measurement_start_failed of
      { slot_id : string
      ; detail : string
      ; evidence : string
      }
  | Before_measurement_dispatch_callback_failed of { evidence : string }
  | Measurement_terminal_callback_failed of { evidence : string }
  | Before_dispatch_callback_failed of
      { slot_id : string
      ; call_id : string
      ; evidence : string
      }
  | Before_advance_callback_failed of
      { next_slot_id : string
      ; evidence : string
      }
  | Candidates_exhausted of
      { slot_id : string
      ; detail : string
      ; evidence : string
      }
  | Candidate_execution_failed of
      { slot_id : string
      ; call_id : string
      ; cause : Agent_core.Exact_output.execution_error_cause
      ; raw_response_sha256 : string option
      ; evidence : string
      }

type execution_error =
  | Exact_execution_failed of
      { failure : exact_execution_failure
      ; prior_semantic_rejections : semantic_rejection list
      }
  | Semantic_candidates_exhausted of semantic_rejection list
  | Proposal_store_failed of Store.error

type prepared

type success = private
  { proposal : Proposal.t
  ; store_result : Store.save_result
  ; run_id : string
  ; selected_slot : string
  }

val lane_id : string

val prepare
  :  config:Workspace.config
  -> keeper_name:string
  -> Request.t
  -> (prepared, setup_error) result
(** Freeze one ordered exact-output flow from the published Assembler lane.
    No provider request, proposal write, or ordinary Tool dispatch occurs. *)

val execute
  :  net:Eio_context.eio_net
  -> ?clock:_ Eio.Time.clock
  -> ?observation_registry:Exact_lane_run_registry.t
  -> prepared
  -> (success, execution_error) result
(** Execute the frozen flow exactly once. Semantic rejection advances only to
    the next frozen candidate. Success publishes the proposal but never calls
    [keeper_plan_execute] or any ordinary Tool dispatcher. *)

val setup_error_to_yojson : setup_error -> Yojson.Safe.t
val semantic_rejection_to_yojson : semantic_rejection -> Yojson.Safe.t
val exact_execution_failure_to_yojson : exact_execution_failure -> Yojson.Safe.t
val execution_error_to_yojson : execution_error -> Yojson.Safe.t
