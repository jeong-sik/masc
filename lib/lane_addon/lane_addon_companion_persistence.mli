(** Persistence ownership shared by original invocations and their notices.
    The records, schemas and recovery-lane identities remain with each caller. *)

val with_creation_owner :
  path:string ->
  unavailable:'error ->
  commit_unconfirmed:'error ->
  (unit -> ('a, 'error) result) ->
  ('a, 'error) result
(** Make one non-blocking attempt at the stable [path] publication-owner lock.
    Validate the lock file's owner, mode, link count and inode before admission,
    after acquisition and after the callback. The publication-owner inode stays
    separate from the private JSONL transaction lock and is never removed.
    Missing lock files are accepted only before acquisition. The existing
    durable lock protects admitted work through release and propagates body
    exceptions, including cancellation, without replaying the callback.

    [unavailable] represents inspection/acquisition failure. Contention, a
    changed post-callback inode or release failure is [commit_unconfirmed].
    A completed callback's own result is preserved only after confirmed release.
    These values belong to the caller's closed error type. *)

val existing_leaf : Fs_compat.capability_write_error -> bool
(** True only for exclusive-creation refusal at a known unchanged existing
    target, with no write cleanup failure. This permits strict reconciliation;
    it does not certify that a stored record matches or settle a recovery lane. *)
