(** What failed when a terminal tool effect failed (RFC-0454 D1).

    Each constructor names one producer's failure. Leaf strings are messages
    for people (a tool's own message, agent-core's detail); no code reads them
    to decide anything. Structured evidence stays structured: a composition's
    failure object is [payload], a JSON value, so serializing the error never
    escapes that value into a string.

    A tool is named in the namespace its producer holds.
    [internal_tool_name] is the keeper descriptor's internal name, the one
    dispatch and telemetry use. [model_tool_name] is the name the model called.
    [composition_tool] is the composition's own tool name.

    The module lives in [masc.keeper_runtime] because the failure crosses
    [masc.runtime] (official-client transports) and [Keeper_internal_error],
    both of which sit below the keeper library that produces it. *)

type failed_node =
  { node_id : string
  ; model_tool_name : string
  ; message : string
  }

(** Which plan execution error stopped a composition node, by kind. The typed
    error lives above this library; [payload] keeps its full JSON. *)
type plan_execution_error =
  | Unknown_node_id
  | Input_template_resolution_failed
  | Input_validation_failed
  | Output_validation_failed
  | Output_not_composable

(** How a node deferred, by kind. [Deferral_unrecorded] is a producer that
    settled [Deferred] without stating which kind, not a default for a kind
    this decoder does not know. *)
type node_deferral =
  | Deferral_unrecorded
  | Generic_deferral
  | External_effect_deferral

(** The composition executor's failure cause, projected without its JSON. *)
type composition_cause =
  | Node_failed of failed_node
      (** A node failed. *)
  | Node_deferred of
      { node_id : string
      ; model_tool_name : string
      ; deferral : node_deferral
      }
      (** A node deferred. It produces no composable output, so the plan stops
          there; that is not the same event as a node failing, and the node's
          deferred data is a JSON document, so it stays in [payload] instead
          of being stringified into a message. *)
  | Node_observation_failed of
      { node_id : string
      ; model_tool_name : string
      ; detail : string
      }
      (** A node completed and recording its result failed. *)
  | Plan_execution_failed of
      { node_id : string
      ; error : plan_execution_error
      }

(** Why the recovery proposal tool refused a proposal. *)
type recovery_rejection =
  | Recovery_store_failed
  | Recovery_source_unavailable
  | Recovery_submission_invalid
  | Recovery_projection_rejected

type t =
  | Tool_failed of
      { internal_tool_name : string
      ; message : string
      }
  | Composition_failed of
      { composition_tool : string
      ; cause : composition_cause
            (** A typed projection of the executor cause, not another copy of
                its JSON. *)
      ; payload : Yojson.Safe.t
            (** The composition's failure object as the tool result carries
                it. Display only; never read to decide. *)
      }
  | Composition_result_manifest_unpersisted of
      { composition_tool : string
      ; detail : string
      }
  | Composition_evidence_unpublished of
      { composition_tool : string
      ; detail : string
      }
  | Terminal_tool_receipt_missing of { internal_tool_name : string }
  | Terminal_composition_receipt_missing of { composition_tool : string }
  | Output_artifact_unstored of { message : string }
  | Output_over_inline_budget of { message : string }
  | Result_delivery_failed of
      { model_tool_name : string
      ; message : string
      }
  | Boundary_observation_failed of
      { model_tool_name : string
      ; cause : Keeper_request_failure_core.t
            (** The observation returned an agent-core error; it is kept as the
                typed projection, not as its rendered text. *)
      }
  | Recovery_proposal_rejected of
      { model_tool_name : string
      ; rejection : recovery_rejection
      ; message : string
      }
  | Agent_core_terminal_effect of { detail : string }
      (** Agent-core's [TerminalTool{Effect,Durability}Failed.detail]; agent-core
          owns that text. *)

val summary : t -> string
(** One line for people: line breaks inside leaf messages become spaces.
    Computed from the value, never stored. *)

val to_yojson : t -> Yojson.Safe.t
(** A JSON object tagged by ["kind"]. [payload] is written as the value it is. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Strict: an unknown [kind], a missing or extra field, or a field of the
    wrong shape is [Error]. Nothing is filled with a default. [payload]
    accepts any JSON value, as [to_yojson] writes any. *)
