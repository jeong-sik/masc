(** Offline posts initialization. Inspection creates no files. Mutations require
    exclusive, quiescent ownership of the existing BasePath; the server adapter
    acquires the actual configured BasePath lease. This API does not admit a
    live Board store; normal loads and writers independently check the guard. *)
type inspection
type outcome
type decision = Bootstrap_required | Adoption_required | Ready_observed | Refused
type completion = Completed | Not_completed

val live_guard_enforced : bool
(** Read-only live policy report, independent of the result of an offline action. *)

val inspect : base_path:string -> inspection
val decision : inspection -> decision
val intent_sha256 : inspection -> string option
(** Logical root/action/content intent, never a cursor or write receipt. *)
val posts_source_sha256 : inspection -> string option
val inspection_to_yojson : inspection -> Yojson.Safe.t
val finish_inspection : inspection -> unit
(** Pure settlement: retain and reraise the first original reserved exception. *)

val bootstrap_offline :
  base_path:string -> expected_intent_sha256:string -> outcome
val adopt_offline :
  base_path:string -> expected_intent_sha256:string -> outcome
val completion : outcome -> completion
val outcome_to_yojson : outcome -> Yojson.Safe.t
val finish_outcome : outcome -> completion
(** Pure, no retry or I/O. Completed requires both current write receipts and no
    terminal refusal, unknown effect or retained reserved exception. Ordinary
    descriptor cleanup diagnostics do not discard a known durable receipt. *)

module For_testing : sig
  type file_io = {
    posts : Fs_compat.private_jsonl_transaction_io_for_testing;
    guard : Fs_compat.private_jsonl_transaction_io_for_testing;
  }
  type io = { read : file_io; write : file_io }
  val inspect : base_path:string -> io:file_io -> inspection
  val bootstrap_offline :
    base_path:string -> expected_intent_sha256:string -> io:io -> outcome
  val adopt_offline :
    base_path:string -> expected_intent_sha256:string -> io:io -> outcome
  (** Immutable per-file seams use the actual Fs transactions. Read includes
      inspection and stable preparation; write runs only after both snapshots
      are known. No fabricated snapshot or admission callback is accepted. *)
end
