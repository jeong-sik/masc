(** Shell IR projection for deterministic IDE command descriptors. *)

val compute : Masc_exec.Shell_ir.t -> Ide_event_types.command_descriptor
(** Compute a structured command descriptor from Shell IR. *)
