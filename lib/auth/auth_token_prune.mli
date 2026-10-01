(** Retire expired credentials and orphaned redirect stubs against the current
    credential store. A listing or inventory snapshot is never deletion authority. *)

type reason = Expired | Orphaned_redirect
type mode = Preview | Retire
type outcome = Would_retire | Retired | Failed of Masc_domain.masc_error
type entry = { agent_name : string; reason : reason; outcome : outcome }

val run :
  base_path:string -> now:float -> mode:mode ->
  (entry list, Masc_domain.masc_error) result
(** One Auth credential transaction owns discovery, canonical-name reads,
    expiry classification and deletion/cache invalidation. A read, ownership or admission
    error aborts before any deletion. Undecodable and mismatched credentials
    are preserved. Only ENOENT proves a redirect target absent; unreadable or
    dangling targets are preserved or refuse the operation. Credential and
    redirect JSON reads require owned regular files: symbolic links and special
    nodes refuse the whole plan. The opened descriptor's kind and identity are
    checked before reading. Relative base paths and directory aliases resolve
    through the canonical store root, without following a JSON leaf. Raw-token
    sidecars keep their existing presence and
    unlink semantics, including dangling links. A redirect must
    agree with its resolved credential's UUID. Any extra UUID deletion target
    must resolve to that same credential; a forged pointer refuses planning.

    Validated aliases of an expired UUID owner are retired in the same plan.
    Canonical metadata is removed last, preserving discovery for a cleanup retry.
    Raw-token publication and credential publication share the prune transaction.

    [Preview] reports [Would_retire] without changing credentials or token caches.
    An absent store returns an empty plan without creating its directory or lock.
    [Retire] reports each completed deletion as [Retired]. A deletion error is
    [Failed], which can follow partial file removal; later entries are still
    attempted. The caller must count only [Retired] as completed retirement. *)
