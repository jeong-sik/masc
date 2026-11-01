(** Immutable ownership projections for one admitted Keeper credential batch.

    Admission-time sharing remains fixed while the current ownership snapshot
    changes after publication or an authoritative failure reread. No bearer
    hashing, validation, clock, logging, path resolution or I/O occurs here. *)

type ownership =
  (Auth_credential_base.stored_credential * Masc_domain.agent_credential) list

type admitted_shared
type current

val admit : ownership -> admitted_shared * current
(** Capture every shared hash once and retain input order within each bucket.
    The caller supplies the transaction's canonical current-owner snapshot. *)

val refreshed : ownership -> current
(** Replace current ownership entirely after the caller's authoritative reread.
    Bucket entries are prepended in snapshot order, reversing each bucket as
    in the existing failure-refresh path. *)

val ownership : current -> ownership
(** Keep the original snapshot order, or the last published owner first. *)

val was_shared : admitted_shared -> string -> bool
(** Test a credential hash against the unchanged batch-admission evidence. *)

val owners_for_hash : current -> string -> Masc_domain.agent_credential list option
(** [None] means no bucket. Retired buckets may remain [Some []]; the existing
    token validator treats either as no matching credential. *)

val published :
  current -> stored:Auth_credential_base.stored_credential ->
  Masc_domain.agent_credential -> current
(** Retire the preceding same-name owner from its old bucket, prepend the
    supplied owner to its new bucket and replace its stored ownership row.
    The caller has already completed publication and resolved its stored form. *)
