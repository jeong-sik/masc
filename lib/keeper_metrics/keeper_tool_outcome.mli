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
  | Resource_conflict of { resource : string }
  | No_work_available

(** JSON serialization for telemetry and trace surfaces. *)
val to_json : t -> Yojson.Safe.t

(** JSON deserialization from tool output embedding. Malformed input
    returns [None]. *)
val of_json : Yojson.Safe.t -> t option
