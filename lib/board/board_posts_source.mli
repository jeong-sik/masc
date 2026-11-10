(** Stable posts source for one captured store. Board persistence locks are
    owned by the caller; this module never recursively acquires them. *)
open Board_types

type reserved_settlement = {
  result : (unit, board_error) result;
  exception_ : exn;
  backtrace : Printexc.raw_backtrace;
}
exception Reserved_settlement of reserved_settlement
(** Internal known-primary carrier, unwrapped after all enclosing Board locks.
    [result] preserves success versus proven nonwrite for batch retry marking. *)

type snapshot
val capture : ?replacement:post -> store -> snapshot
val append : store -> post -> posts_write_outcome
type creation_append =
  | Creation_append_outcome of posts_write_outcome
  | Creation_policy_refused of {
      failure : Fs_compat.private_jsonl_guard_failure;
      outcome : posts_write_outcome;
    }
val append_creation_with_policy : store ->
  policy:sub_boards_source_observation -> post -> creation_append
(** The create caller holds persistence and has validated this exact policy
    snapshot against the post author/hearth. Retain Posts -> Policy scopes
    through append, without reacquiring Posts. Only actual inner refusal is
    [Creation_policy_refused]; the caller notifies that Policy source owner
    before finishing reserved diagnostics. Pin/close/reopen keep plain append.
    Filesystem workers receive captured values and never mutate source state. *)
val rewrite : store -> snapshot -> posts_write_outcome
val read : store -> posts_source_read
val publish_read : store -> posts_source_read -> unit
val require_readable : store -> (unit, board_error) result
(** Pure: unobserved, refused and unsettled phases never authorize posts.
    An unsettled store stays unauthorized until [settle] proves the unknown
    write's outcome; plain [read] never settles. *)
val failure_to_board_error : posts_source_failure -> board_error
val finish_write : posts_write_outcome -> (unit, board_error) result
val finish_read : posts_source_read -> unit
val read_diagnostics : posts_source_read -> posts_source_diagnostic list
val write_diagnostics : posts_write_outcome -> posts_source_diagnostic list
val settle_diagnostics : posts_settle_outcome -> posts_source_diagnostic list
type settle_direction =
  | Direction_landed
  | Direction_absent
  | Direction_diverged
val settle_direction_for_testing :
  pending:posts_unsettled_write -> Fs_compat.private_jsonl_snapshot -> settle_direction
(** Pure settlement direction of one observation against retained
    unknown-write evidence. Test and diagnostic entry only: production
    verdicts run inside [settle] under persistence with a fresh locked
    read, workspace revalidation and a durability proof. This function
    grants no authority. *)
val settle : store -> posts_settle_outcome
(** Settle the retained unknown write of an unsettled store. Caller owns
    persistence; this function revalidates the workspace of the pre-write
    observation, performs one locked posts read and at most one durable proof
    rewrite, and never touches the in-memory post tables.

    The verdict jointly consults the recorded transaction failure, the
    pre-write observation and the intended bytes: a nonwrite verdict restores
    the pre-write observation so a caller retry stays fenced by its cursor,
    and a written verdict is issued only after the observed bytes are proven
    durable. A store that is not unsettled yields
    [Posts_settle_nothing_to_settle] with no IO. *)
val diagnostic_to_string : posts_source_diagnostic -> string
val reserved_diagnostics : posts_source_diagnostic list ->
  (exn * Printexc.raw_backtrace) option
val fail_read : store -> posts_source_read -> stage:posts_source_stage ->
  exn -> Printexc.raw_backtrace -> posts_source_read * posts_source_failure
(** Retain the current trace when later model publication or reporting raises.
    Caller owns persistence; this function performs no IO. *)

val reserved_exception :
  exn * Printexc.raw_backtrace -> (exn * Printexc.raw_backtrace) option
(** Classify reserved causes while retaining the original combined exception. *)
val reserved_transaction :
  Fs_compat.private_jsonl_transaction_error ->
  (exn * Printexc.raw_backtrace) option
val definitely_not_written : Fs_compat.private_jsonl_transaction_error -> bool
val propagate_reserved : exn -> Printexc.raw_backtrace -> unit
val defer_reserved :
  result:(unit, board_error) result -> exn -> Printexc.raw_backtrace -> unit
