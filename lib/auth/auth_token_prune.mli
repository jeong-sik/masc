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
    dangling targets are preserved or refuse the operation. A redirect must
    agree with its resolved credential's UUID. Any extra UUID deletion target
    must resolve to that same credential; a forged pointer refuses planning.

    [Preview] reports [Would_retire] without changing files or token caches.
    [Retire] reports each completed deletion as [Retired]. A deletion error is
    [Failed], which can follow partial file removal; later entries are still
    attempted. The caller must count only [Retired] as completed retirement. *)
