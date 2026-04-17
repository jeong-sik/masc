(** A3 — the single privileged exec entry point.

    The gate refuses any input that is not a [Verdict.Trusted_argv.t]
    at the type level — [Verdict.Allow] is the only verdict arm that
    carries one.  [Verdict.Ask] and [Verdict.Deny] come back as a
    structured outcome rather than a shell invocation.

    This A3-PR-1 module is a dispatcher skeleton.  The wired-through
    call to [Process_eio.run_argv_with_status] lands in the A4 cutover
    PRs alongside the 87-site migration; today [run] on [Allow] simply
    reports [`Allowed] so callers can thread the surface and tests can
    lock the shape. *)

type error =
  [ `Ask_required of Verdict.request
  | `Denied of Verdict.deny_reason
  ]
(** Non-allow outcomes.  [Ask_required] carries the approval request
    so the caller may route it through the approval queue.  [Denied]
    is terminal — no user-approved override exists. *)

val run : Verdict.t -> (Verdict.Trusted_argv.t, error) result
(** [run verdict] dispatches on the three verdict arms.

    On [Allow trusted], returns [Ok trusted].  A follow-up A4 PR wires
    this into the single [Process_eio.run_argv_with_status] call site,
    producing the actual command output.  Today the Ok payload is the
    trusted argv itself so downstream tests can read [bin], [args],
    and [redirects] through the [Trusted_argv] accessors. *)
