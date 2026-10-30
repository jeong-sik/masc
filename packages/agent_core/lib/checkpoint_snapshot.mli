(** Immutable, strictly encoded checkpoint fact. The journal owns occurrence
    identity; this value contains no recovery or execution permission. *)
type stage =
  | After_input_wait_changed
  | After_assistant_collected
  | After_tool_results_appended
  | After_context_injection
  | After_rejected_response_dropped
val stage_to_string : stage -> string

type error = Invalid_checkpoint of Error.t | Invalid_snapshot of string
val error_to_string : error -> string

type t
val create : stage:stage -> Checkpoint.t -> (t, error) result
(** Freeze through the strict checkpoint codec; later context mutation cannot
    change this fact. *)
val stage : t -> stage
val agent_name : t -> string
val turn : t -> int
val timestamp : t -> float
val checkpoint : t -> (Checkpoint.t, error) result
(** Decode a fresh checkpoint/context for each reader. *)
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, error) result
