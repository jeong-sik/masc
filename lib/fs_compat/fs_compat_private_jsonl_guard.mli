open Fs_compat_private_jsonl_transaction

type private_jsonl_guard_failure = {
  guard_path : string;
  guard_error : private_jsonl_transaction_error;
}

type 'a private_jsonl_guard_result =
  | Guard_refused of private_jsonl_guard_failure
  | Guard_executed of {
      value : 'a;
      cleanup_failures : private_jsonl_guard_failure list;
    }

type 'a private_jsonl_dependency_guard_result =
  | Dependency_is_target of {
      target_path : string;
      dependency_path : string;
    }
  | Dependency_guarded of 'a private_jsonl_guard_result
(** [Dependency_is_target]: the dependency names the file whose stable lock the
    target guard already holds, judged by that lock file's device and inode.
    The dependency guard never started and nothing was appended. *)

val with_private_jsonl_snapshot_guard_result :
  string -> expected:private_jsonl_snapshot ->
  f:(unit -> 'a) -> 'a private_jsonl_guard_result
(** Validate exact bytes/cursor and retain this path's existing stable lock
    through [f]. Refused means [f] never ran; executed preserves its exact value
    separately from later guard descriptor cleanup. The callback runs in the
    blocking worker: filesystem effects only, no Eio effects or model mutation.
    It must not re-enter this path. Callers order any nested guarded paths and
    target locks consistently; this is not an arbitrary multi-file transaction. *)

val with_private_jsonl_snapshot_guard_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string -> expected:private_jsonl_snapshot ->
  f:(unit -> 'a) -> 'a private_jsonl_guard_result

val append_private_jsonl_durable_locked_at_snapshot_with_dependency_result :
  string -> expected:private_jsonl_snapshot ->
  dependency_path:string -> dependency:private_jsonl_snapshot -> string ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result
    private_jsonl_dependency_guard_result private_jsonl_guard_result
(** Acquire the target stable scope, then the distinct read dependency scope.
    A dependency that is the target file itself, under any spelling, returns
    [Dependency_is_target] instead of re-entering the target lock; a dependency
    lock entry that cannot be inspected is an inner refusal.
    Both exact snapshots stay guarded through the existing append body, without
    re-entering the target lock. Outer/inner refusal proves no append ran; the
    nested executed values retain the real append result separately from each
    guard's cleanup failures. All callbacks run in the filesystem worker. *)

val append_private_jsonl_durable_locked_at_snapshot_with_dependency_with_io_for_testing :
  ?io:private_jsonl_transaction_io_for_testing ->
  ?dependency_io:private_jsonl_transaction_io_for_testing ->
  string -> expected:private_jsonl_snapshot ->
  dependency_path:string -> dependency:private_jsonl_snapshot -> string ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result
    private_jsonl_dependency_guard_result private_jsonl_guard_result
