(** gh-backed external verifier for the grounding reconciler (RFC-0259 §3.3 P2).

    The single external-IO surface. Shells out to [gh pr|issue view <id> --json
    state]; any failure (network, 404, auth, timeout) or a non-gh kind ([Task] /
    Jira) yields [Unverifiable], so the reconciler never treats uncertainty as
    contradiction. Injected into the reconciler as a {!Keeper_memory_os_reconcile.verify_fn}. *)

open Keeper_memory_os_types

val verify_external
  :  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> repo:string
  -> external_ref
  -> Keeper_memory_os_reconcile.external_state
