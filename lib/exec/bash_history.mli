type process_status =
  | Exited of int
  | Signaled of int
  | Stopped of int

type history_entry =
  { ts : float
  ; command : string
  ; duration_ms : int
  ; status : process_status
  }

val process_status_of_unix : Unix.process_status -> process_status
val process_status_to_json : process_status -> Yojson.Safe.t
val entry_to_json : history_entry -> Yojson.Safe.t

val append :
  base_path:string ->
  keeper_name:string ->
  history_entry ->
  (unit, exn) result
(** Append the exact command and objective process result to the keeper's
    JSONL observation stream. Entries are never compacted automatically. *)
