(** Keeper_github_change_lookup — what a submitted pull request looks like at
    the moment the authority judges it.

    The workspace's output lands as merged pull requests. Until now the
    evidence grammar could read only files inside the producer's sandbox, so a
    producer that said "it is in #30715" had its evidence recorded as an
    invalid reference and the authority judged on nothing (RFC-0453 §3.5).

    Read where the authority reads the evidence, not where the producer files
    it. The submit boundary runs inside the backlog lock
    ([workspace_task_transitions.ml] holds it across the verification-request
    hook), and that lock is a lease with a wall-clock expiry: a repository
    that answers slowly there would hold every other transition in the
    workspace behind it. The judging lane holds no such lock.

    No new credential: the bearer is the token the producer's own [gh] CLI
    already holds, read from its hosts file at the moment of asking
    ({!Keeper_github_identity.stored_token}). A producer with no token gets a
    typed failure, not a silent gap and not somebody else's identity. *)

type http_get =
  url:string
  -> headers:(string * string) list
  -> (int * string, string) result
(** Injected transport: status code and body text, or a transport error.
    Production passes the shared local-runtime client; tests pass a stub. *)

val lookup :
  http_get:http_get ->
  token:(string, string) result ->
  repository:string ->
  pull_request:int ->
  Workspace_verification_store.change_lookup
(** Never raises and never returns [Change_not_looked_up]: this function did
    look. Every failure — no token, transport, status, malformed body, a
    repository or number that does not resolve — comes back as
    {!Workspace_verification_store.Change_lookup_failed} with what went wrong,
    so the authority reads why it cannot see the change. *)

val reader :
  config:Workspace_utils_backend_setup.config ->
  worker:string ->
  repository:string ->
  pull_request:int ->
  Workspace_verification_store.change_lookup
(** The production reader, called by the completion-authority lane as it
    reads one snapshot. [worker] is the Task's assignee, so a change is looked
    up as the producer that submitted it rather than as the judge. *)
