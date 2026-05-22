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
  required_tool_excluded_count : int;
  all_goals_excluded : bool;
}

(** JSON serialization for telemetry and trace surfaces. *)
val to_json : t -> Yojson.Safe.t
