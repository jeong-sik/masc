(** Explicit operator observation and terminal resolution of an original
    waiting/lost Composition owner. Never retries effects or replaces a run. *)
type t
type outcome =
  | Observed of Keeper_tool_execution_journal.resolution_observation
  | Resolved of Keeper_tool_execution_journal.resolution_report

val parse_tool_command : Yojson.Safe.t -> (t, string) result
val execute : base_path:string -> actor:string -> now:float -> t ->
  (outcome, Keeper_tool_execution_journal.error) result
val outcome_to_json : outcome -> Yojson.Safe.t
