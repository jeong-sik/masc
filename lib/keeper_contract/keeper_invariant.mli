(** Mathematical verification framework for keeper runtime invariants.

    Defines invariants that can be checked at runtime or verified offline:
    - Sandbox isolation: No cross-turn filesystem leakage
*)

(** Unique identifier for a keeper turn. *)
type turn_id = string

(** Absolute path within a sandbox. *)
type sandbox_path = string

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
