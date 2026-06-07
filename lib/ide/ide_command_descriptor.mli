(** Compatibility wrapper for deterministic command descriptors.

    New non-IDE callers should use [Command_descriptor] directly. *)

val compute : Masc_exec.Shell_ir.t -> Ide_event_types.command_descriptor
(** Compute a structured command descriptor from Shell IR. *)
