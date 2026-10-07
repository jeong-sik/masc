(** Count overflow is work for the Librarian, not an eviction policy.
    Run on the existing per-Keeper Librarian lane at boot, post-turn or intake
    wake, including when there is no unread conversation. *)

type outcome =
  | Disabled
  | Within_limits
  | Already_reviewed
  | Reviewed of { remaining_excess : bool }
  | Unavailable of string

val run : base_path:string -> keeper_name:string -> outcome

val forget : base_path:string -> keeper_name:string -> unit
(** Forget a purged Keeper's observation. *)

module For_testing : sig
  val run_with :
    execute:(keepers_dir:string -> keeper_name:string -> expected_revision:int ->
             Keeper_librarian.input -> bool) ->
    base_path:string -> keeper_name:string -> outcome
end
