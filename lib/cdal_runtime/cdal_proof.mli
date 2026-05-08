(** CDAL proof bundle -- 15-field contract-driven execution evidence.

    Part of the Contract-Driven Agent Loop (CDAL) PoC-1.

    Distinct from {!Sessions_types.proof_bundle} which is a 25+ field
    internal conformance structure. This type is the cross-repo evidence
    manifest consumed by downstream coordinators.

    Agent code is NOT proof-aware. Proof capture is performed
    entirely by middleware hooking into the agent lifecycle.

    @stability Evolving
    @since 0.93.1 *)

type result_status =
  | Completed (** Agent reached EndTurn *)
  | Errored (** Hook crash, verifier crash, unexpected runtime failure *)
  | Timed_out (** max_turns exceeded or wall-clock timeout *)
  | Cancelled (** Hook/policy gate intentionally blocked continuation *)
  | Context_overflow (** Provider rejected request due to context window exhaustion *)
[@@deriving yojson, show]

type provider_snapshot =
  { provider_name : string
  ; model_id : string
  ; api_version : string option
  }
[@@deriving yojson, show]

type capability_snapshot =
  { tools : string list
  ; mcp_servers : string list
  ; max_turns : int
  ; max_tokens : int option
  ; thinking_enabled : bool option
  }
[@@deriving yojson, show]

(** Artifact reference. Format: ["proof-store://{run_id}/..."]. *)
type artifact_ref = string [@@deriving yojson, show]

type t =
  { schema_version : int
  ; run_id : string
  ; contract_id : string
  ; requested_execution_mode : Execution_mode.t
  ; effective_execution_mode : Execution_mode.t
  ; mode_decision_source : string
  ; risk_class : Risk_class.t
  ; provider_snapshot : provider_snapshot
  ; capability_snapshot : capability_snapshot
  ; tool_trace_refs : artifact_ref list
  ; raw_evidence_refs : artifact_ref list
  ; checkpoint_ref : artifact_ref option
  ; result_status : result_status
  ; started_at : float
  ; ended_at : float
  ; scope : string option
  }
[@@deriving yojson, show]

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val schema_version_current : int
