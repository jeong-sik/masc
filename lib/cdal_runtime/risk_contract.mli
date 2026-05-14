(** Risk contract for contract-driven agent runs.

    Part of the Contract-Driven Agent Loop (CDAL) PoC-1.

    A risk contract has two surfaces:
    - [runtime_constraints]: enforced by OAS at execution time
    - [eval_criteria]: opaque passthrough carried to the proof bundle

    @stability Evolving
    @since 0.93.1 *)

(** Runtime constraints enforced by OAS. *)
type runtime_constraints =
  { requested_execution_mode : Execution_mode.t
  ; risk_class : Risk_class.t
  ; allowed_mutations : string list
  ; review_requirement : string option
  }
[@@deriving yojson, show]

(** Eval criteria -- opaque to OAS, consumed by downstream coordinators post-eval. *)
type eval_criteria = Yojson.Safe.t [@@deriving yojson, show]

type t =
  { runtime_constraints : runtime_constraints
  ; eval_criteria : eval_criteria
  }
[@@deriving yojson, show]

(** Content-addressed hash of the canonical JSON representation.
    Format: ["md5:{hex}"] for PoC, upgradeable to ["sha256:{hex}"]. *)
val contract_id : t -> string

(** Canonical JSON string (sorted keys, compact) for external verification. *)
val canonical_json : t -> string
