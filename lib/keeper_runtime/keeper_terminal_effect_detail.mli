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
      ; failed_node : failed_node option
            (** The node the executor cause names as not completing. [None]
                when the cause is not a node that failed. A typed projection of
                that node, not another copy of its JSON. *)
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
      ; message : string
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
