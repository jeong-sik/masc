(** P13 — Exit code semantic interpretation.

    Maps [Unix.process_status] to structured, LLM-readable meanings
    so agents can self-correct instead of blind retry. *)

type category =
  | Success
  | General_error
  | Usage_error
  | Data_error
  | Permission_error
  | Not_found
  | Timeout
  | Oom_killed
  | Segfault
  | Signal of int
  | Unknown of int

type t = {
  raw : Unix.process_status;
  code : int;
  category : category;
  label : string;
  hint : string;
}

val of_process_status : Unix.process_status -> t
val is_success : t -> bool
val to_assoc : t -> (string * Yojson.Safe.t) list
val to_json : t -> Yojson.Safe.t
