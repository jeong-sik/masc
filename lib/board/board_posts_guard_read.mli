(** Actual stable-sibling guard reads. Validation is separate so the caller
    observes descriptor settlement before decoding or further physical IO.
    This module never imports Inspection, CorePersist or Source. *)
type read =
  | Read of Fs_compat.private_jsonl_snapshot Fs_compat.private_jsonl_success_receipt
  | Failed of Fs_compat.private_jsonl_transaction_error
  | Raised of exn * Printexc.raw_backtrace
val read : ?io:Fs_compat.private_jsonl_transaction_io_for_testing ->
  path:string -> unit -> read
val validate : Fs_compat.private_jsonl_snapshot -> Board_posts_guard_rows.validation
(** Count actual complete physical rows, including blanks, and share the pure
    framing/schema owner. No snapshot/cursor is manufactured or recovered. *)
