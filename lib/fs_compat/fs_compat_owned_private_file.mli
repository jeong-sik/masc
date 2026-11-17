open Fs_compat_owned_file
open Fs_compat_durable_append
open Fs_compat_private_jsonl_transaction

type 'error owned_file_update_error =
  | Owned_observation_failed of owned_regular_file_read_error
  | Underlying_update_failed of 'error

val update_owned_private_file_durable_locked_result :
  ?owner_uid:int -> ownership_root:string -> string ->
  (owned_regular_file_contents -> string option * 'a) ->
  ('a, durable_append_error owned_file_update_error) private_file_transaction_outcome
(** Create/update one data leaf in an already prepared owned parent. Admission
    precedes creation or permission changes. The callback borrows the actual
    transaction bytes and descriptor snapshot; it must not reopen the path.
    No sidecar is created. The existing private writer's unique-leaf policy,
    append/fsync/rollback and primary/close-failure outcomes are preserved.
    Eio cancellation waits for settlement and does not discard a committed
    receipt. Callbacks must not suspend or reopen this cooperating path. *)

val update_existing_owned_private_file_durable_locked_result :
  ?owner_uid:int -> ownership_root:string -> string ->
  (owned_regular_file_contents -> string option * 'a) ->
  ('a option, private_jsonl_transaction_error owned_file_update_error)
    private_file_transaction_outcome
(** Existing-only sibling. Missing parent/data returns a successful [None],
    without creating anything or invoking the callback. Both APIs require one
    hard link, as their matching existing private-file writers already do.
    Ownership remains optional: [None] retains the owned reader's no-follow and
    immediate-parent identity policy without adding UID/parent-mode authority. *)

module Owned_private_file_for_testing : sig
  val create :
    io:private_jsonl_transaction_io_for_testing ->
    ?owner_uid:int -> ownership_root:string -> string ->
    (owned_regular_file_contents -> string option * 'a) ->
    ('a, durable_append_error owned_file_update_error) private_file_transaction_outcome
  val existing :
    io:private_jsonl_transaction_io_for_testing ->
    ?owner_uid:int -> ownership_root:string -> string ->
    (owned_regular_file_contents -> string option * 'a) ->
    ('a option, private_jsonl_transaction_error owned_file_update_error)
      private_file_transaction_outcome
  val path_mutex_available : string -> bool
end
