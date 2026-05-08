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
      target : string;
    } -> (unit, string, [ `Privileged ], [ `Host ]) command

  | Generic : Shell_ir.simple ->
      (Shell_ir.simple, string, [ `Privileged ], [ `Host ]) command
(** Catch-all for unknown or unparseable commands.  The risk is pinned to
    [`Privileged] so the policy layer treats it as fail-closed. *)

(** Best-effort conversion from an untyped [Shell_ir.simple] to a typed
    command.  Known binaries with parseable literal arguments are lifted
    to specific constructors; everything else falls through to [Generic]. *)
val of_simple : Shell_ir.simple -> wrapped option

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
