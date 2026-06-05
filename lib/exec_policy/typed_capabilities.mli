(** GADT Capability and Verified Shell IR definitions.

    Risk classification is the single source of truth for shell safety.
    [Safe_IR] wrapping happens after allowlist validation; no redundant
    capability or mutation checks are performed here. *)

type yes = Yes
type no = No

type safe = Safe_tag
type unsafe = Unsafe_tag

type _ verified_ir =
  | Safe_IR : Masc_exec.Shell_ir.t -> safe verified_ir
  | Unsafe_IR : Masc_exec.Shell_ir.t -> unsafe verified_ir

type cap_flags = {
  read_fs : bool;
  write_fs : bool;
  network : bool;
  spawn : bool;
}

val classify_flags : Masc_exec.Exec_program.known -> cap_flags
val classify_program_flags : Masc_exec.Exec_program.t -> cap_flags

val shell_ir : _ verified_ir -> Masc_exec.Shell_ir.t
