open Fs_compat_owned_file
open Fs_compat_private_jsonl_transaction

type owned_private_jsonl_permissions = Owned_regular | Private_0600
type owned_private_jsonl_role = Owned_data | Owned_stable_lock
type owned_private_jsonl_read_error =
  | Owned_admission_failed of
      { role : owned_private_jsonl_role; error : owned_regular_file_read_error }
  | Owned_private_permissions_required of
      { role : owned_private_jsonl_role; path : string; actual : int }
  | Owned_transaction_failed of private_jsonl_transaction_error

val read_owned_private_jsonl_durable_locked_result :
  owner_uid:int -> ownership_root:string ->
  permissions:owned_private_jsonl_permissions -> string ->
  after:Private_jsonl_cursor.t option ->
  (private_jsonl_snapshot, owned_private_jsonl_read_error) result
(** Owned, single-link data and stable-lock admission runs under the canonical
    data-path mutex, before any parent/lock creation or body read. All admission
    descriptors close before the stable lock is acquired. The same mutex then
    covers the unchanged stable-lock snapshot read and its settlement.
    [Private_0600] additionally requires exact 0600 on both existing leaves;
    [Owned_regular] retains their modes (the stable protocol still requires a
    private lock). Missing leaves remain admissible; [after] retains the
    ordinary snapshot reader's missing/cursor semantics. Eio cancellation is
    checked after the worker has settled every descriptor and released the
    mutex; it does not return a stale read result after cancellation. *)

module Owned_private_jsonl_for_testing : sig
  val read :
    parent_lstat:(string -> Unix.stats) ->
    io:private_jsonl_transaction_io_for_testing ->
    owner_uid:int -> ownership_root:string ->
    permissions:owned_private_jsonl_permissions -> string ->
    after:Private_jsonl_cursor.t option ->
    (private_jsonl_snapshot, owned_private_jsonl_read_error) result
  val path_mutex_available : string -> bool
  (** Nonblocking probe of the actual canonical transaction mutex. *)
end
