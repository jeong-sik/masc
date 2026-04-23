type history_entry = {
  ts : float;
  cmd_hash : string;
  cmd_prefix : string;
  semantic_kind : string;
  duration_ms : int;
  success : bool;
}

val entry_to_json : history_entry -> Yojson.Safe.t

val append :
  base_path:string ->
  keeper_name:string ->
  history_entry ->
  unit
(** Append one entry to the keeper's JSONL history file.  Creates the
    directory and file if they don't exist. *)

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

val cmd_hash : string -> string
(** Truncated SHA-256 (12 hex chars) of a command string. *)
