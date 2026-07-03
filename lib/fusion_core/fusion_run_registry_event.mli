(** JSONL event type for fusion run registry persistence.

    Every state-changing operation on {!Fusion_run_registry.t} appends one
    event line to disk. On server boot the log is replayed to restore recent
    run history. *)

type t =
  | Register of
      { run_id : string
      ; keeper : string
      ; preset : string
      ; started_at : float
      }
  | Complete of
      { run_id : string
      ; ok : bool
      ; failure : string option
      ; failure_code : string option
      }

val to_yojson : t -> Yojson.Safe.t
(** Canonical JSON object for one event. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Parse an event from a JSON object; [Error] on unknown event kind. *)

val to_jsonl : t -> string
(** Single JSONL line (JSON object + trailing newline). *)
