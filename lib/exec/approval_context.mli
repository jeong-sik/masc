(** Approval_context — runtime state the policy consults at decision
    time (but does not capture into the Verdict itself).

    The context names the actor, the session, and the worktree root so
    the policy can thread them into subsequent layers (approval queue
    source field, audit log, drawer UI) without plumbing them through
    every call site.

    Fields are intentionally narrow.  This module is additive in
    follow-ups: a per-agent TOML overlay will land alongside
    Approval_config but only after we can point at a real consumer. *)

type t = {
  actor : Agent_id.t;
  (** Typed agent identity for who is triggering the exec.  [`Coord_git] for
      the git coordinator, [`System_task_sandbox] for the sandbox runner,
      etc.  Not a security principal — that stays with the token/session on
      the transport layer. *)

  session_id : string;
  (** Opaque session id threaded from the transport.  The approval queue
      uses this to route Ask outcomes back to the originating client. *)

  worktree_root : string;
  (** Absolute canonical path to the MASC worktree root.  Policy uses it
      to decide whether a [Path_scope.Inside_worktree] is this worktree or
      some other one the caller might have mounted. *)

  now : float;
  (** Wall-clock at decision time, seconds since epoch.  Fed from the
      caller's Eio clock rather than [Unix.gettimeofday] so tests can
      inject a deterministic value. *)
}

val make :
  actor:Agent_id.t ->
  session_id:string ->
  worktree_root:string ->
  now:float ->
  t
(** Plain smart constructor; no validation yet (the policy layer
    that actually consumes these fields will add it). *)
