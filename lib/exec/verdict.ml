module Trusted_argv = struct
  type t =
    { bin : Bin.t
    ; args : Shell_ir.arg list
    ; env : (string * Shell_ir.arg) list
    ; cwd : Path_scope.t option
    ; redirects : Redirect_scope.t list
    }

  let bin t = t.bin
  let args t = t.args
  let env t = t.env
  let cwd t = t.cwd
  let redirects t = t.redirects
end

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

let trust ~caps:_ (s : Shell_ir.simple) : Trusted_argv.t =
  { bin = s.bin; args = s.args; env = s.env; cwd = s.cwd; redirects = s.redirects }
;;
