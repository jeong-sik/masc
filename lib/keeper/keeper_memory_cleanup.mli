(** Count overflow is work for the Librarian, not an eviction policy.
    Run on the existing per-Keeper Librarian lane at boot, post-turn or intake
    wake, including when there is no unread conversation. *)

type review_result =
  | Limits_reached
  | Progress_with_excess
  | Excess_retained

type outcome =
  | Disabled
  | Within_limits
  | Already_reviewed
  | Reviewed of review_result
  | Unavailable of string

val run : base_path:string -> keeper_name:string -> outcome
(** A committed decision that reduces category or item excess without worsening
    the other emits the existing Librarian queue signal when excess remains.
    A refusal, unchanged count or rewrite does not schedule another pass. *)

val forget : base_path:string -> keeper_name:string -> unit
(** Forget a purged Keeper's observation. *)

module For_testing : sig
  val run_with :
    execute:(keepers_dir:string -> keeper_name:string -> expected_revision:int ->
             Keeper_librarian.input -> bool) ->
    base_path:string -> keeper_name:string -> outcome
end
