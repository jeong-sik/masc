(** Mathematical verification framework for keeper runtime invariants.

    Defines invariants that can be checked at runtime or verified offline:
    - Sandbox isolation: No cross-turn filesystem leakage
    - Credential isolation: GitHub credentials are not mixed between keepers
    - Tool surface monotonicity: Available tools only shrink when explicitly configured
*)

(** Unique identifier for a keeper turn. *)
type turn_id = string

(** Absolute path within a sandbox. *)
type sandbox_path = string

(** Scope of a GitHub credential bundle. *)
type credential_scope =
  { keeper_id : string
  ; github_account : string
  }

(** Normalised tool identifier. *)
type tool_name = string

(** {1 Sandbox Isolation} *)

(** [sandbox_isolation ~sandbox_roots ~sandbox_paths] checks that every path in
    [sandbox_paths] is equal to or prefixed by at least one root in
    [sandbox_roots]. A path equal to a root is permitted (the root itself is
    a valid sandbox path). Violations indicate a potential container escape
    or mount misconfiguration. *)
val sandbox_isolation
  :  sandbox_roots:sandbox_path list
  -> sandbox_paths:sandbox_path list
  -> (unit, string) Result.t

(** {1 Credential Isolation} *)

(** [credential_isolation ~keeper ~credential ~other_keepers] returns [Ok ()]
    iff no entry in [other_keepers] uses the same [github_account] as
    [credential] under a different [keeper_id]. This prevents accidental
    credential reuse across personas; a single keeper may legitimately hold
    multiple github accounts, and self-duplicates are not treated as
    violations.

    The [~keeper] argument is retained for API compatibility but is not used
    for the comparison: the authoritative identity is [credential.keeper_id],
    which avoids the bug where a divergent [~keeper] value would mask
    legitimate conflicts. *)
val credential_isolation
  :  keeper:string
  -> credential:credential_scope
  -> other_keepers:credential_scope list
  -> (unit, string) Result.t

(** {1 Tool Surface Monotonicity} *)

(** [tool_surface_monotonicity ~before ~after] returns [Ok ()] when the
    tool set available [after] is a subset of [before].  In other words,
    tools may only be removed by explicit configuration, never silently
    added at runtime. *)
val tool_surface_monotonicity
  :  before:tool_name list
  -> after:tool_name list
  -> (unit, string) Result.t

(** {1 Composite Checks} *)

(** Run all three invariants and return the first error, if any. *)
val check_all
  :  sandbox_roots:sandbox_path list
  -> sandbox_paths:sandbox_path list
  -> keeper:string
  -> credential:credential_scope
  -> other_keepers:credential_scope list
  -> before_tools:tool_name list
  -> after_tools:tool_name list
  -> (unit, string) Result.t
