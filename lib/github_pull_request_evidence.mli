(** GitHub reader for [pull-request:] evidence references (masc#28989).

    The verification store owns the evidence contract but stays free of
    transport dependencies, so the composition root installs {!inspect}
    into it at startup via
    [Workspace_verification_store.install_pull_request_inspector].

    Two GETs against api.github.com per snapshot: the pull-request object
    (state, merged, draft, head sha, title) and the diff, the latter
    bounded by the store's evidence byte cap. Unauthenticated — the
    target repos are public; a non-200 comes back as a typed
    [Pull_request_http_status] the verifier can reason about. *)

val inspect :
  Workspace_verification_store.pull_request_locator ->
  ( Workspace_verification_store.pull_request_snapshot
  , Workspace_verification_store.pull_request_fetch_failure )
  result

val install : unit -> unit
(** [install ()] registers {!inspect} as the store's forge reader. Call once
    from the server composition root, beside the other startup capability
    installs. *)
