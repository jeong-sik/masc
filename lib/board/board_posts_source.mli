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
val rewrite : store -> snapshot -> posts_write_outcome
val read : store -> posts_source_read
val publish_read : store -> posts_source_read -> unit
val require_readable : store -> (unit, board_error) result
val failure_to_board_error : posts_source_failure -> board_error
val finish_write : posts_write_outcome -> (unit, board_error) result
val finish_read : posts_source_read -> unit
val reserved_exception :
  exn * Printexc.raw_backtrace -> (exn * Printexc.raw_backtrace) option
(** Classify reserved causes while retaining the original combined exception. *)
val reserved_transaction :
  Fs_compat.private_jsonl_transaction_error ->
  (exn * Printexc.raw_backtrace) option
val propagate_reserved : exn -> Printexc.raw_backtrace -> unit
(** Reraise an exception containing a reserved cause, including nested Eio
    multiple failures, with the original exception and backtrace intact. *)
