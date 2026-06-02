type history_entry = {
  ts : float;
  cmd_hash : string;
  cmd_prefix : string;
  semantic_kind : string;
  duration_ms : int;
  success : bool;
}

(** Detected failure pattern for P15: Repeated Failure Detection. *)
type failure_pattern =
  | Repeated_failure of { cmd_prefix : string; count : int }
  | High_failure_rate of { recent : int; failures : int; rate : float }
  | Timeout_cluster of { cmd_prefix : string; count : int }

val failure_pattern_to_json : failure_pattern -> Yojson.Safe.t
(** Serialize a failure pattern to JSON for consumption by the agent. *)

val entry_to_json : history_entry -> Yojson.Safe.t

val append :
  base_path:string ->
  keeper_name:string ->
  history_entry ->
  (unit, exn) result
(** Append one entry to the keeper's JSONL history file.  Creates the
    directory and file if they don't exist.

    Returns [Error exn] on [Sys_error] from [open_out_gen] / output /
    close.  Previously these raised through to keeper tool dispatch
    and surfaced as a tool failure even though the tool itself had
    completed.  The audit trail is best-effort; callers decide whether
    to swallow + observe or propagate. *)

val compact :
  base_path:string ->
  keeper_name:string ->
  unit
(** When the file exceeds [max_entries] (10 000) lines, rewrite it
    keeping only the last [compact_to] (1 000) entries.  Call
    periodically (e.g. after each append). *)

val suggest :
  base_path:string ->
  keeper_name:string ->
  pattern:string ->
  limit:int ->
  history_entry list
(** Return the last [limit] entries whose [cmd_prefix] or [cmd_hash]
    starts with [pattern].  Returns [] when the file doesn't exist. *)

val failure_insight :
  base_path:string ->
  keeper_name:string ->
  failure_pattern list
(** Analyze recent history for stuck-loop patterns:
    - [Repeated_failure]: same command failed N times consecutively
    - [High_failure_rate]: overall failure rate exceeds threshold
    - [Timeout_cluster]: same command timed out N times consecutively
    Returns [] when no patterns are detected or file doesn't exist. *)

val cmd_hash : string -> string
(** Truncated SHA-256 (12 hex chars) of a command string. *)
