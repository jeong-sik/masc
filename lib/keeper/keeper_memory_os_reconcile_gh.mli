(** GitHub-backed external verifier for the grounding reconciler (RFC-0259 §3.3 P2).

    The single external-IO surface. Uses GitHub GraphQL through
    {!Masc_http_client} and a MASC-managed token; expected lookup failures
    (network, 404, auth, timeout, malformed response) or a non-GitHub kind
    ([Task] / Jira) yield [Unverifiable], while Eio cancellation still
    propagates. The reconciler never treats uncertainty as contradiction.
    Injected into the reconciler as a
    {!Keeper_memory_os_reconcile.verify_fn}. *)

open Keeper_memory_os_types

val parse_state_response
  :  kind:external_ref_kind
  -> string
  -> Keeper_memory_os_reconcile.external_state

val no_token_verify
  : external_ref -> Keeper_memory_os_reconcile.external_state

val verify_external
  :  token:string
  -> clock:[> float Eio.Time.clock_ty ] Eio.Resource.t
  -> timeout_sec:float
  -> repo:string
  -> external_ref
  -> Keeper_memory_os_reconcile.external_state
