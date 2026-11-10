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
