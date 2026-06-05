(** GADT Capability and Verified Shell IR definitions. *)

type yes = Yes
type no = No

type safe = Safe_tag
type unsafe = Unsafe_tag

type _ verified_ir

type cap_flags = {
  read_fs : bool;
  write_fs : bool;
  network : bool;
  spawn : bool;
}

type promotion_error =
  | Unsafe_capability of string
  | Mutation_not_allowed of string

val classify_flags : Masc_exec.Exec_program.known -> cap_flags
val classify_program_flags : Masc_exec.Exec_program.t -> cap_flags

val promote :
  Masc_exec.Shell_ir.t ->
  (safe verified_ir, promotion_error) result

val shell_ir : _ verified_ir -> Masc_exec.Shell_ir.t
