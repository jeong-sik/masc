(** The [outcome] a keeper turn's decision-log row records. The writer
    ([Keeper_unified_metrics_decision.append_decision_record]) takes this
    type and the readers parse the written label back into it. *)

type t =
  | Success  (** The turn finished. *)
  | Checkpoint  (** The turn stopped at a checkpoint to resume later. *)
  | Input_required  (** The turn stopped waiting for input. *)
  | Failed  (** The turn failed. Written as ["error"]. *)

val to_string : t -> string
(** ["success"], ["checkpoint"], ["input_required"], ["error"]. *)

val of_string : string -> t option
(** Exact match on {!to_string}. [None] for anything else, including padded
    or empty strings. *)
