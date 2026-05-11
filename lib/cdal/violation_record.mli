(** Violation_record — Typed violation records from CDAL proof artifacts.

    Re-exports [Masc_mcp_cdal_runtime.Mode_enforcer] canonical types and provides
    MASC-specific constraint algebra (minimum_required_mode).

    @since CDAL eval content-based redesign
    @see Masc_mcp_cdal_runtime.Mode_enforcer for canonical serializers *)

(** Violation kind — re-exported from [Masc_mcp_cdal_runtime.Mode_enforcer.violation_kind]. *)
type violation_kind = Masc_mcp_cdal_runtime.Mode_enforcer.violation_kind =
  | Mutating_in_diagnose (** workspace mutation attempted in Diagnose mode *)
  | External_in_draft (** external effect attempted in Draft mode *)
  | Scope_violation (** violated allowed_mutations constraint *)

(** A single violation record — re-exported from [Masc_mcp_cdal_runtime.Mode_enforcer.violation]. *)
type t = Masc_mcp_cdal_runtime.Mode_enforcer.violation =
  { ts : float
  ; tool_name : string
  ; input_summary : string
  ; effective_mode : Masc_mcp_cdal_runtime.Execution_mode.t
  ; violation_kind : violation_kind
  }

(** Parse a single violation from JSON.
    Delegates to [Masc_mcp_cdal_runtime.Mode_enforcer.violation_of_yojson].

    @warning This returns [Error] for unrecognized [violation_kind] or
    [effective_mode]. Call sites should decide explicitly whether to surface,
    aggregate, or ignore parse failures, rather than assuming legacy
    [Unknown] fallback behavior. *)
val of_json : Yojson.Safe.t -> (t, string) result

(** Parse an array of violations from JSON.

    Each element is parsed via {!of_json}. If any entry fails strict parsing,
    the whole function returns [Error]. *)
val of_json_list : Yojson.Safe.t -> (t list, string) result

(** The minimum execution mode that would have prevented this violation.
    - [Mutating_in_diagnose] -> [Draft]
    - [External_in_draft] -> [Execute]
    - [Scope_violation] -> [Execute] *)
val minimum_required_mode : t -> Masc_mcp_cdal_runtime.Execution_mode.t

(** Violation kind to/from string. Delegates to OAS canonical functions. *)
val violation_kind_to_string : violation_kind -> string

val violation_kind_of_string : string -> (violation_kind, string) result
