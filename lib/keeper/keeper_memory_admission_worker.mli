type judgment_result =
  | Committed
  | Deferred of string
  | Input_size_refused of string

type outcome =
  | Disabled
  | Idle
  | Settled of { has_more : bool }
  | Pending of string
  | Unavailable of string

val run : base_path:string -> keeper_name:string -> outcome
(** Runs on the existing serialized Memory lane, independently of current fact
    counts. Restores consumed input before considering candidates. A successful
    subset may leave deferred rows. [Settled.has_more] only names remaining rows
    beyond the highest sequence evaluated in this batch (including an unevaluated
    suffix after a size refusal), never already-evaluated deferred gaps. No private retry loop
    is started for uncertainty or outages. *)

module For_testing : sig
  val run_with :
    keepers_dir:string -> keeper_name:string ->
    judge:(Keeper_memory_admission_queue.batch -> judgment_result) -> outcome
end
