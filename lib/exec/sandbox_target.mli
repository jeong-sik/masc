(** Sandbox target abstraction consumed by the Shell_ir dispatch path.

    See [sandbox_target.ml] for the rationale. The short version: this
    type lets [Shell_ir.simple] carry the sandbox decision as data while
    keeping [lib/exec] independent of [lib/keeper] (the keeper layer
    injects its Docker runtime via the [runner] closure).

    [t] is a variant rather than a record so that the [Host] case needs
    no runner.  The dispatch path in [Exec_dispatch] routes [Host]
    directly to [Exec_gate], avoiding a circular dependency between
    [Sandbox_target] and [Exec_gate]. *)

(** A runner closure executes an argv with the given env / cwd / timeout
    and returns the raw process status plus stdout/stderr buffers.
    Exceptions are propagated; callers in [Exec_dispatch] catch and
    translate them into structured dispatch results. *)
type runner =
  argv:string list ->
  env:string array ->
  cwd:string option ->
  timeout_sec:float ->
  Unix.process_status * string * string

type t =
  | Host
  | Docker of { image : string; runner : runner }

(** Default host target.  The dispatch path routes this directly to
    [Exec_gate]; no runner is carried. *)
val host : unit -> t

(** Build a Docker target.  The caller (typically [lib/keeper]) supplies
    the runner closure; this keeps [lib/exec] from having to know about
    [Keeper_turn_sandbox_runtime] or any other keeper-side construct. *)
val docker : image:string -> runner:runner -> t

val pp : Format.formatter -> t -> unit
