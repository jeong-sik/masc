(** Descriptor-relative cleanup of an execution-owned tree after its writer
    has stopped. Retained parent identities authorize recovery of an already
    removed target. No links are followed and no other tree is traversed. *)
type directory =
  { path : string
  ; device : int
  ; inode : int
  ; owner_uid : int
  ; permissions : int
  }

val remove : directory list -> (unit, string) result
(** The ordered chain starts at the canonical ownership root and ends at a
    strict descendant to remove. Every component is frozen by the producer.
    The caller excludes writers for this transaction; this is not an atomic
    POSIX compare-unlink against an unrelated writer bypassing that ownership.
    Blocking: run the whole scope on a system thread in Eio contexts.
    Partial removal or failed fsync stays an explicit error. Re-entry accepts
    only the original target identity or absence under unchanged parents. *)
