(** Anti-rationalization gate for task completion.

    Verifies that completion notes actually address the task rather than
    containing avoidance patterns ("out of scope", "will do later", etc.).

    Inspired by Trail of Bits' Stop hook anti-rationalization pattern:
    a separate model reviews the primary agent's work before accepting it.

    When the LLM reviewer is unavailable, falls back to local pattern matching
    only. Liveness takes priority over correctness.

    @since v2.145.0 *)

(** Review request: task context + agent's completion claim. *)
type review_request = {
  task_title : string;
  task_description : string;
  completion_notes : string;
  agent_name : string;
}

(** Gate verdict. *)
type verdict =
  | Approve
  | Reject of string

(** Review a task completion claim.
    Returns [Approve] if notes are substantive and address the task.
    Returns [Reject reason] if notes contain avoidance patterns or are vague.
    On LLM failure, defaults to [Approve] (liveness > correctness). *)
val review : review_request -> verdict

(** Check notes for known excuse patterns (local, no LLM).
    Returns [Some (pattern, reason)] if a match is found.
    Exposed for testing. *)
val find_excuse_pattern : string -> (string * string) option

(** Parse LLM output into a verdict.
    "APPROVE" -> [Approve], "REJECT: reason" -> [Reject reason].
    Unrecognized format defaults to [Approve] (liveness).
    Exposed for testing. *)
val parse_verdict : string -> verdict
