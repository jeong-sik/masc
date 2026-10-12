type judgment_result =
  | Committed
  | Awaiting_evidence
  | Deferred of string
  | Input_size_refused of string

type outcome =
  | Disabled
  | Idle
  | Recheck_new_input
  | Settled of { has_more : bool }
  | Pending of string
  | Unavailable of string

val run : base_path:string -> keeper_name:string -> outcome
(** Runs on the existing serialized Memory lane, first judging the full batch.
    Only an actual input-size refusal partitions it into disjoint whole-input
    halves, and only when the same walk met no failure a smaller range meets
    the same way (a quota, an outage, an operator refusal): such a walk is
    deferred whole. Semantic [Awaiting_evidence] and singleton size refusal preserve
    that part and continue its unevaluated siblings; ordinary [Deferred] errors
    stop the pass, including after earlier successful commits. Each runtime
    judgment rereads current Memory. No deferred slice is retried within a pass.
    After original partitions finish, [Settled.has_more] names only a newly
    appended tail beyond the original batch's maximum sequence. Deferred gaps
    alone never schedule another wake. If no part committed, a new tail produces
    [Recheck_new_input], otherwise [Pending]. [Settled] always means at least one
    receipt-backed commit. Partitioning does not prove semantic independence. *)

module For_testing : sig
  val judgment_of_not_committed : Keeper_librarian_runtime.not_committed -> judgment_result
  val keep_strongest_judgment :
    judgment_result -> Keeper_librarian_runtime.not_committed -> judgment_result
  val run_with :
    keepers_dir:string -> keeper_name:string ->
    judge:(Keeper_memory_admission_queue.batch -> judgment_result) -> outcome

  (** [Input_size_refused] only when the walk shows size and met no failure a
      smaller range meets the same way; [Deferred] otherwise. *)
end
