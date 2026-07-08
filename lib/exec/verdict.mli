(** Verdict — four-way outcome of the approval policy.

    [Trusted_argv.t] is a [private] record whose only constructor is
    [Verdict.trust], which lives in [Approval_policy].  Downstream code
    (the exec gate) therefore cannot forge a trusted argv — it can only
    receive one that the policy has produced.

    This is the single most important type in the RFC v5 refactor:
    the exec path refuses anything that is not a [Trusted_argv.t]. *)

module Trusted_argv : sig
  type t = private {
    bin : Exec_program.t;
    args : Shell_ir.arg list;
    env : (string * Shell_ir.arg) list;
    cwd : Path_scope.t option;
    redirects : Redirect_scope.t list;
  }

  val bin : t -> Exec_program.t
  val args : t -> Shell_ir.arg list
  val env : t -> (string * Shell_ir.arg) list
  val cwd : t -> Path_scope.t option
  val redirects : t -> Redirect_scope.t list
end

type confirm_token = {
  risk_class : Exec_program.risk_class;
  ttl_sec : float;
}
(** Opaque token for future HITL confirmation flow.
    The [risk_class] identifies which trust level triggered the suggestion. *)

type request = {
  caps : Capability.t list;
  summary : string;
  bin : Exec_program.t;
  raw_source : string;
}

type deny_reason =
  | Unknown_bin of string
  | Path_escape of Path_scope.t
  | Destructive_git of Git_op.t
  | Destructive_db of Db_op.t
      (** A destructive SQL statement ([DROP]/[TRUNCATE]/[DELETE]) handed to a
          database CLI ([psql -c], [mysql -e]).  Part of the trust-independent
          catastrophic floor — the typed replacement for the legacy
          [sql_destructive] substring patterns (RFC
          eliminate-substring-destructive-classifier §3-A). *)
  | Destructive_repo_hosting_cli of Exec_program.t
      (** An irreversible repository-hosting CLI operation (for example
          [gh repo delete] or [gh api -X DELETE]). Part of the
          trust-independent catastrophic floor so autonomous keepers cannot
          mutate remote repository state irreversibly through the generic exec
          surface. Reversible durable-remote mutations such as [gh repo create]
          and ordinary [gh pr merge] are represented by [Ask] through the gh
          capability axis instead; admin-bypass merge is [Policy_deny]. *)
  | Catastrophic_program of Exec_program.t
      (** A binary that is never legitimate for a keeper regardless of its
          arguments (e.g. the filesystem-format binary, or system-power
          [shutdown]/[reboot]/[halt]/[poweroff]).  Part of the trust-independent
          catastrophic floor — RFC-0254 §5.4. *)
  | Policy_deny of { rule : string }
  | Parse_too_complex of Parsed.reason_too_complex
  | Parse_failed

type t =
  | Allow of Trusted_argv.t
  | Suggest_confirm of Trusted_argv.t * confirm_token
  | Ask of request
  | Deny of { caps : Capability.t list; reason : deny_reason }
(** Four-way verdict.  [Suggest_confirm] auto-allows but marks the
    decision as "suggested for confirmation" in telemetry.  When the
    approval trust level is [Suggest], the policy produces this variant
    instead of a plain [Allow] so the gate can log the suggestion. *)

val trust :
  caps:Capability.t list ->
  Shell_ir.simple ->
  Trusted_argv.t
(** The {i only} way to mint a [Trusted_argv.t].  Intended to be called
    from [Approval_policy.decide] after a capability list has been
    approved. *)

val deny_reason_to_string : deny_reason -> string
(** Render a [deny_reason] to a human-readable diagnostic.  Exhaustive over
    every constructor so adding a new [deny_reason] is a compile error here
    rather than a silent fallback to a generic string at the call site. *)
