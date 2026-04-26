(** A2 — exhaustive walker from [Shell_ir.t] to [Capability.t list].

    Invariant: adding a new [Shell_ir] arm forces a compile error here
    (exhaustive match on closed sum).  The walker is the single point
    where every shell construct is mapped to the policy vocabulary.

    Fail-closed rule: if a construct would produce {e nothing}, the
    walker never silently drops it.  Either it maps to a capability
    (possibly [Exec_bin] on the unknown-bin path) or the parser should
    have rejected it upstream as [Parsed.Too_complex _]. *)

(** Walk a single command.  Order of emitted caps:
    1. [Env_set] for every [FOO=bar] prefix, in source order.
    2. [Exec_bin] or [Git] for the command itself.
    3. [Read_path]/[Write_path] for every redirect, in source order. *)
val of_simple : Shell_ir.simple -> Capability.t list

(** Walk a full [Shell_ir.t].  For [Pipeline], emits a single
    [Pipeline_fold] wrapping the concatenated per-stage caps. *)
val of_ir : Shell_ir.t -> Capability.t list
