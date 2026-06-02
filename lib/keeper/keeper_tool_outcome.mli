(** Keeper_tool_outcome — typed representation of tool execution results.

    Replaces string-based result classification at the determinism boundary.
    Each tool handler constructs a value of this type; downstream pipeline
    matches exhaustively without parsing strings.

    @since task-555 *)

type t =
  | Progress
  | No_progress of { reason : no_progress_reason }
  | Error of { reason : string }

and no_progress_reason =
  | No_eligible_tasks of claim_scope_exclusions
  | Resource_conflict of { resource : string }
  | No_work_available

and claim_scope_exclusions = {
  scope_excluded_count : int;
  blocked_count : int;
  verification_blocked_count : int;
  all_goals_excluded : bool;
}

(** JSON serialization for telemetry and trace surfaces. *)
val to_json : t -> Yojson.Safe.t

(** JSON deserialization from tool output embedding. *)
val of_json : Yojson.Safe.t -> t option

(** Remove [typed_outcome] field from JSON before returning to LLM. *)
val strip_from_json : Yojson.Safe.t -> Yojson.Safe.t

(** Closed set of [no_work_reason] enum values accepted by keeper_stay_silent as a
    typed no-work proof. SSOT shared by the tool schema and the handler. *)
val stay_silent_no_work_reasons : string list

(** Parse a keeper_stay_silent [no_work_reason] argument into the typed no-work
    proof outcome. Returns [None] for unknown or empty values (unknown is not a
    permissive default), which leaves a bare stay_silent a contract violation
    under an actionable signal. *)
val no_work_reason_of_stay_silent_arg : string -> t option
