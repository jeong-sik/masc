(** Stable posts source for one captured store. Board persistence locks are
    owned by the caller; this module never recursively acquires them. *)
open Board_types

val live_guard_enforced : bool
(** Built-in live admission policy, reported by offline tooling; not a switch
    or evidence that any particular store was admitted. *)

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
val rewrite : store -> snapshot -> posts_write_outcome
val read : store -> posts_source_read
val publish_read : store -> posts_source_read -> unit
val require_readable : store -> (unit, board_error) result
(** Pure: guard-only, refused and unsettled phases never authorize posts. *)
val failure_to_board_error : posts_source_failure -> board_error
val finish_write : posts_write_outcome -> (unit, board_error) result
val finish_read : posts_source_read -> unit
val read_diagnostics : posts_source_read -> posts_source_diagnostic list
val write_diagnostics : posts_write_outcome -> posts_source_diagnostic list
val diagnostic_to_string : posts_source_diagnostic -> string
val reserved_diagnostics : posts_source_diagnostic list ->
  (exn * Printexc.raw_backtrace) option
val fail_read : store -> posts_source_read -> stage:posts_source_stage ->
  exn -> Printexc.raw_backtrace -> posts_source_read * posts_source_failure
(** Retain the current trace when later model publication or reporting raises.
    Caller owns persistence; this function performs no IO. *)

type initialization_check
val check_initialization : store -> initialization_check
(** Real guard-only admission under persistence. It never loads posts or clears
    a posts refusal. Unsettled returns before all workspace/file IO. *)
val initialization_result : initialization_check -> (unit, posts_source_failure) result
val initialization_diagnostics : initialization_check -> posts_source_diagnostic list
val initialization_exception : store -> initialization_check ->
  exn -> Printexc.raw_backtrace -> initialization_check
val finish_initialization : result:(unit, board_error) result -> initialization_check -> unit
(** Carry the caller's one actual requested-file precondition result through
    enclosing Board locks; success is not a payload or publication receipt. *)

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
