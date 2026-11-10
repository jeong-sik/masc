open Board_types

type t = private {
  post_id : Post_id.t;
  parent : posts_source_observation;
  comment : comments_source_observation option;
}
(** Canonical parent authority for one new vote/reaction. [comment = None]
    means a post target. A comment target retains its exact comment-to-post
    link as well as the post snapshot. Existing orphan rows remain loadable. *)

val capture : store -> reader:Board_access.reader ->
  target_type:reaction_target_type -> target_id:string -> (t, board_error) result
(** Caller holds persistence then state. Decode complete snapshots, check the
    actual reader, and refuse stale authority/routing fields in the model.
    Closed threads and sub-board posting policy impose no new restriction. *)

val revalidate : store -> t -> (unit, Board_workspace_binding.rejection) result

type dependency = Parent_posts | Parent_comments
type refusal = {
  dependency : dependency;
  failure : Fs_compat.private_jsonl_guard_failure;
  cleanup_failures : Fs_compat.private_jsonl_guard_failure list;
}
type 'a guarded =
  | Refused of refusal
  | Executed of {
      value : 'a;
      cleanup_failures : Fs_compat.private_jsonl_guard_failure list;
    }

val guard : t ->
  posts_io:Fs_compat.private_jsonl_transaction_io_for_testing option ->
  comments_io:Fs_compat.private_jsonl_transaction_io_for_testing option ->
  f:(unit -> 'a) -> 'a guarded
(** Retain Posts -> optional Comments through the leaf filesystem callback.
    Capture paths/snapshots/IO before calling. The callback runs in the blocking
    worker: filesystem effects only, no Board state or reader callbacks.
    Refused proves the leaf callback did not run. Executed preserves its actual
    value separately from inner-to-outer parent cleanup failures. *)

val observe_refusal : store -> t -> refusal -> unit
(** Outside the filesystem worker, notify only the exact refused parent owner.
    This does not revoke a leaf source whose write was never attempted. *)
