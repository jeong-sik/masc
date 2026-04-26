(** Verdict — four-way outcome of the approval policy.

    [Trusted_argv.t] is a [private] record whose only constructor is
    [Verdict.trust], which lives in [Approval_policy].  Downstream code
    (the exec gate) therefore cannot forge a trusted argv — it can only
    receive one that the policy has produced.

    This is the single most important type in the RFC v5 refactor:
    the exec path refuses anything that is not a [Trusted_argv.t]. *)

module Trusted_argv : sig
  type t = private
    { bin : Bin.t
    ; args : Shell_ir.arg list
    ; env : (string * Shell_ir.arg) list
    ; cwd : Path_scope.t option
    ; redirects : Redirect_scope.t list
    }

  val bin : t -> Bin.t
  val args : t -> Shell_ir.arg list
  val env : t -> (string * Shell_ir.arg) list
  val cwd : t -> Path_scope.t option
  val redirects : t -> Redirect_scope.t list
end

(** Opaque token for future HITL confirmation flow.
    The [risk_class] identifies which trust level triggered the suggestion. *)
type confirm_token =
  { risk_class : Bin.risk_class
  ; ttl_sec : float
  }

type request =
  { caps : Capability.t list
  ; summary : string
  ; bin : Bin.t
  ; raw_source : string
  }

type deny_reason =
  | Unknown_bin of string
  | Path_escape of Path_scope.t
  | Destructive_git of Git_op.t
  | Policy_deny of { rule : string }
  | Parse_too_complex of Parsed.reason_too_complex
  | Parse_failed

type t =
  | Allow of Trusted_argv.t
  | Suggest_confirm of Trusted_argv.t * confirm_token
  | Ask of request
  | Deny of
      { caps : Capability.t list
      ; reason : deny_reason
      }
  (** Four-way verdict.  [Suggest_confirm] auto-allows but marks the
    decision as "suggested for confirmation" in telemetry.  When the
    approval trust level is [Suggest], the policy produces this variant
    instead of a plain [Allow] so the gate can log the suggestion. *)

(** The {i only} way to mint a [Trusted_argv.t].  Intended to be called
    from [Approval_policy.decide] after a capability list has been
    approved. *)
val trust : caps:Capability.t list -> Shell_ir.simple -> Trusted_argv.t
