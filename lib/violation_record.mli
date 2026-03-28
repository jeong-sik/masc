(** Violation_record — Typed violation records from CDAL proof artifacts.

    Parses the JSON written by OAS [Proof_capture.collect_evidence_refs]
    into typed OCaml records. Provides constraint algebra for deriving
    the minimum execution mode that would prevent each violation.

    @since CDAL eval content-based redesign *)

(** Violation kind — mirrors Mode_enforcer's classification. *)
type violation_kind =
  | Mutating_in_diagnose  (** workspace mutation attempted in Diagnose mode *)
  | External_in_draft     (** external effect attempted in Draft mode *)
  | Scope_violation       (** violated allowed_mutations constraint *)
  | Unknown of string     (** unrecognized violation_kind from JSON *)

(** A single violation record as written by Proof_capture. *)
type t = {
  ts : float;
  tool_name : string;
  input_summary : string;
  effective_mode : Agent_sdk.Execution_mode.t;
  violation_kind : violation_kind;
}

(** Parse a single violation from JSON. *)
val of_json : Yojson.Safe.t -> (t, string) result

(** Parse an array of violations from JSON. *)
val of_json_list : Yojson.Safe.t -> (t list, string) result

(** The minimum execution mode that would have prevented this violation.
    This is the inverse of [Mode_enforcer.check_violation]:
    - [Mutating_in_diagnose] -> [Draft]
    - [External_in_draft] -> [Execute]
    - [Scope_violation] -> [Execute]
    - [Unknown _] -> the violation's [effective_mode] (no change) *)
val minimum_required_mode : t -> Agent_sdk.Execution_mode.t

(** Violation kind to string for JSON serialization. *)
val violation_kind_to_string : violation_kind -> string
