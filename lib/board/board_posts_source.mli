(** Stable posts source for one captured store. Board persistence locks are
    owned by the caller; this module never recursively acquires them. *)
open Board_types

val observe_guard_refusal : store -> posts_source_observation ->
  Fs_compat.private_jsonl_guard_failure -> unit
(** Retain a contradictory external guard observation only for this exact
    current source. No filesystem IO or model publication is performed. *)

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
    An unsettled store retains its unknown-write evidence and rejects further
    source reads and writes. A fresh store loads the actual source instead. *)
type reobservation =
  | Reobservation_not_due
      (** Readable, never observed, or no longer the refusal the caller found
          due ({!Board_source_file.still_due}). The file was not read. *)
  | Reobserved of posts_source_read
      (** The store is still refused as the caller found it. The caller
          installs the read into the model and {!publish_read}s it. *)
  | Unsettled_write_pending
      (** An earlier write's outcome is unknown. No IO is performed: a read
          cannot prove a durability-unknown publication durable, so only a
          fresh store (server restart) settles it. *)

val reobserve : store -> asked:Board_source_file.refusal -> reobservation
(** Caller holds persistence and found the store due before it waited for it:
    [asked] is what {!refusal} answered then. Re-reads the posts file when
    {!Board_source_file.still_due}, so a write refused because another writer
    appended does not refuse every later write, and a refusal for what the
    file or its lock file was ends once that is repaired. The question is
    answered from the store's fields; the read takes the directory entries
    itself, as its first step. *)

val refusal : store -> Board_source_file.refusal
(** What the posts state says about reading the file again, from its fields
    alone. Refused for a cause {!fresh_read_can_clear} accepts: [Read_again].
    Refused for any other cause: [Read_again_once_changed] with what the
    refusal carries (#55465). A read takes the entries of the file and of its
    lock file before anything else, and its refusal carries them whatever the
    read then met, so a cause that lasts is met once and not at every call.
    A refusal no read made (a write, a guard) carries [Unread] and is read
    again at the next call. Every other phase: [Not_refused]. *)

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

val reserved_exception :
  exn * Printexc.raw_backtrace -> (exn * Printexc.raw_backtrace) option
(** Classify reserved causes while retaining the original combined exception. *)
val reserved_transaction :
  Fs_compat.private_jsonl_transaction_error ->
  (exn * Printexc.raw_backtrace) option
val definitely_not_written : Fs_compat.private_jsonl_transaction_error -> bool

val fresh_read_can_clear : Fs_compat.private_jsonl_transaction_error -> bool
(** Whether a refusal with this cause is read again before the next
    operation: a cursor or content mismatch, a path that changed during the
    operation, or a contended lock. A torn tail, a second hard link, a file
    that is not regular and a failed operation are not: a refusal for one
    is read again only once its file or its lock file is no longer what the
    refusal carries ({!refusal}, #55465). Every Board source asks this before
    it reads again (#55449). *)
val propagate_reserved : exn -> Printexc.raw_backtrace -> unit
val defer_reserved :
  result:(unit, board_error) result -> exn -> Printexc.raw_backtrace -> unit
