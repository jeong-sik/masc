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
}

(** JSON serialization for telemetry and trace surfaces. *)
val to_json : t -> Yojson.Safe.t

(** JSON deserialization from tool output embedding. *)
val of_json : Yojson.Safe.t -> t option

(** Is this typed outcome a no-progress signal ([No_progress _] or [Error _])?
    [None] is [false], preserving the legacy name-based behavior when a tool
    does not emit a typed outcome. Single owner of the outcome gate shared by
    the no-progress detector and the unified-metrics substantive check. *)
val is_nonprogress : t option -> bool

(** Remove [typed_outcome] field from JSON before returning to LLM. *)
val strip_from_json : Yojson.Safe.t -> Yojson.Safe.t
