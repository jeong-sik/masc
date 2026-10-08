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
    prefix may leave a tail for the caller to schedule. No private retry loop
    is started for uncertainty or outages. *)

module For_testing : sig
  val run_with :
    keepers_dir:string -> keeper_name:string ->
    judge:(Keeper_memory_admission_queue.batch -> judgment_result) -> outcome
end
