type failure =
  | Incomplete_tail
  | Append_failed of Fs_compat.durable_append_error
  | Raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type issue =
  { failure : failure
  ; cleanup_failure : Fs_compat.private_jsonl_operation_failure option
  }

type outcome =
  | Durable of { cleanup_failure : Fs_compat.private_jsonl_operation_failure option }
  | Not_committed of issue
  | Indeterminate of issue

val issue_to_string : issue -> string

val append : path:string -> Yojson.Safe.t list -> outcome
(** Uses the shared path mutex and data-descriptor lock, checks only the final
    byte, appends and fsyncs. A complete rollback permits retry; an unobserved
    append or incomplete rollback never does. Existing torn tails are refused
    without changing them. Cancellation must be protected through the caller's
    publication of this result. *)

module For_testing : sig
  val append_with_io :
    append_io:Fs_compat.durable_append_io_for_testing ->
    path:string -> Yojson.Safe.t list -> outcome
end
