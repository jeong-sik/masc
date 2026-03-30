(** Violation_record — Typed violation records from CDAL proof artifacts.

    Re-exports [Agent_sdk.Mode_enforcer] canonical types and provides
    MASC-specific constraint algebra (minimum_required_mode).

    @since CDAL eval content-based redesign
    @see Agent_sdk.Mode_enforcer for canonical serializers *)

(** Violation kind — re-exported from [Agent_sdk.Mode_enforcer.violation_kind]. *)
type violation_kind = Agent_sdk.Mode_enforcer.violation_kind =
  | Mutating_in_diagnose  (** workspace mutation attempted in Diagnose mode *)
  | External_in_draft     (** external effect attempted in Draft mode *)
  | Scope_violation       (** violated allowed_mutations constraint *)

(** A single violation record — re-exported from [Agent_sdk.Mode_enforcer.violation]. *)
type t = Agent_sdk.Mode_enforcer.violation = {
  ts : float;
  tool_name : string;
  input_summary : string;
  effective_mode : Agent_sdk.Execution_mode.t;
  violation_kind : violation_kind;
}

(** Parse a single violation from JSON.
    Delegates to [Agent_sdk.Mode_enforcer.violation_of_yojson]. *)
val of_json : Yojson.Safe.t -> (t, string) result

(** Parse an array of violations from JSON. *)
val of_json_list : Yojson.Safe.t -> (t list, string) result

(** The minimum execution mode that would have prevented this violation.
    - [Mutating_in_diagnose] -> [Draft]
    - [External_in_draft] -> [Execute]
    - [Scope_violation] -> [Execute] *)
val minimum_required_mode : t -> Agent_sdk.Execution_mode.t

(** Violation kind to/from string. Delegates to OAS canonical functions. *)
val violation_kind_to_string : violation_kind -> string
val violation_kind_of_string : string -> (violation_kind, string) result
