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

(** A violation enriched with source-path evidence from the Mode_enforcer
    boundary.  [evidence.source_path] and [evidence.source_line] are
    populated when the violation payload is produced so the call-site
    backtrace survives any subsequent handler discontinuation.

    @since SafeAuto source-path boundary *)
type enriched = {
  base : t;
  evidence : Effect_evidence.t;
}

(** Parse a single violation from JSON.
    Delegates to [Agent_sdk.Mode_enforcer.violation_of_yojson].

    @warning This returns [Error] for unrecognized [violation_kind] or
    [effective_mode]. Call sites should decide explicitly whether to surface,
    aggregate, or ignore parse failures, rather than assuming legacy
    [Unknown] fallback behavior. *)
val of_json : Yojson.Safe.t -> (t, string) result

(** Parse an array of violations from JSON.

    Each element is parsed via {!of_json}. If any entry fails strict parsing,
    the whole function returns [Error]. *)
val of_json_list : Yojson.Safe.t -> (t list, string) result

(** Parse a single violation enriched with [Effect_evidence] from JSON.
    The base fields follow the same strict rules as {!of_json}; the
    [source_path]/[source_line] fields are optional — missing fields
    produce [Effect_evidence.empty].

    @since SafeAuto source-path boundary *)
val of_json_enriched : Yojson.Safe.t -> (enriched, string) result

(** Parse an array of enriched violations from JSON.

    Each element is parsed via {!of_json_enriched}. If any entry fails,
    the whole function returns [Error].

    @since SafeAuto source-path boundary *)
val of_json_list_enriched : Yojson.Safe.t -> (enriched list, string) result

(** [check_source_path_present ev] returns [Ok ()] when
    [ev.evidence.source_path] is [Some _] and
    [Error msg] when it is [None].

    Use this as a regression guard to ensure source-path propagation is
    wired end-to-end at the Mode_enforcer boundary.

    @since SafeAuto source-path boundary *)
val check_source_path_present : enriched -> (unit, string) result

(** The minimum execution mode that would have prevented this violation.
    - [Mutating_in_diagnose] -> [Draft]
    - [External_in_draft] -> [Execute]
    - [Scope_violation] -> [Execute] *)
val minimum_required_mode : t -> Agent_sdk.Execution_mode.t

(** Violation kind to/from string. Delegates to OAS canonical functions. *)
val violation_kind_to_string : violation_kind -> string
val violation_kind_of_string : string -> (violation_kind, string) result
