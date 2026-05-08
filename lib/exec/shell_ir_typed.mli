(** Shell_ir_typed — GADT-based typed command IR (RFC-0005 Week 3 prototype).

    Coexists with the untyped [Shell_ir.t].  Each constructor records the
    command's input type, output type, risk level, and sandbox requirement
    in the GADT parameters so that policy dispatch can be indexed by the
    compiler.

    Fail-closed: any command that does not match a known shape becomes
    [Generic], which carries the full untyped [Shell_ir.simple] and is
    classified at the most restrictive risk level. *)

type risk = [ `Safe | `Audited | `Privileged ]
type sandbox = [ `Host | `Docker ]

(** Existential wrapper so that [of_simple] can return commands with
    different risk and sandbox parameters through a single uniform type. *)
type wrapped = W : ('i, 'o, 'r, 's) command -> wrapped

(** [('i, 'o, 'r, 's) command] indexes by:
    - ['i]: input type (currently [unit] for parsed commands)
    - ['o]: output type ([string] for most, [unit] for side-effect only)
    - ['r]: risk level ([`Safe | `Audited | `Privileged])
    - ['s]: sandbox requirement ([`Host | `Docker]) *)
and (_, _, _, _) command =
  | Ls : {
      path : string option;
      flags : [ `Long | `All | `Human ] list;
    } -> (unit, string, [ `Safe ], [ `Host ]) command

  | Cat : {
      path : string;
    } -> (unit, string, [ `Safe ], [ `Host ]) command

  | Rg : {
      pattern : string;
      path : string option;
      case_sensitive : bool;
    } -> (unit, string, [ `Safe ], [ `Host ]) command

  | Git_status : {
      short : bool;
    } -> (unit, string, [ `Audited ], [ `Host ]) command

  | Git_clone : {
      repo : string;
      branch : string option;
      depth : int;
    } -> (unit, string, [ `Audited ], [ `Host | `Docker ]) command

  | Curl : {
      url : string;
      method_ : [ `GET | `POST | `PUT | `DELETE ];
      headers : (string * string) list option;
      body : string option;
    } -> (unit, string, [ `Audited ], [ `Host ]) command

  | Rm : {
      paths : string list;
      recursive : bool;
      force : bool;
    } -> (unit, unit, [ `Privileged ], [ `Host ]) command

  | Sudo : {
      target_argv : string list;
        (** Tokenized argv for [sudo].  Stored as a list (not
            space-joined) so that quoted arguments — e.g.
            [sudo sh -c "echo hi"] — survive [to_simple] /
            [Capability_check_typed.of_command] without being
            re-split on whitespace. *)
    } -> (unit, string, [ `Privileged ], [ `Host ]) command

  | Generic : Shell_ir.simple ->
      (Shell_ir.simple, string, [ `Privileged ], [ `Host ]) command
(** Catch-all for unknown or unparseable commands.  The risk is pinned to
    [`Privileged] so the policy layer treats it as fail-closed. *)

(** Lift an untyped [Shell_ir.simple] into a typed command.

    Fail-closed: known binaries with parseable literal arguments lift
    to specific constructors; anything that does not match — including
    non-literal args ([Var] / [Concat]), unhandled binary kinds, and
    any [simple] that carries non-empty [env] or [redirects] — falls
    through to [W (Generic s)].  The [Generic] arm pins the risk to
    [`Privileged] and routes capability derivation back to
    [Capability_check.of_simple] so that env / redirect-derived
    [Read_path] / [Write_path] / [Env_set] capabilities are not
    silently dropped on the typed path. *)
val of_simple : Shell_ir.simple -> wrapped

(** Reconstruct an untyped [Shell_ir.simple] from a typed command.
    [env], [cwd], [redirects] and [sandbox] receive default values because
    the typed constructors do not carry them; callers that need the
    original context should retain the source [Shell_ir.simple]. *)
val to_simple : ('i, 'o, 'r, 's) command -> Shell_ir.simple

(** Extract the risk level through the existential wrapper. *)
val risk : wrapped -> risk

(** Extract the sandbox requirement through the existential wrapper. *)
val sandbox : wrapped -> sandbox

val pp : Format.formatter -> wrapped -> unit
