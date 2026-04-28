(** Sandbox target abstraction consumed by the Shell_ir dispatch path.

    See [sandbox_target.ml] for the rationale. The short version: this
    type lets [Shell_ir.simple] carry the sandbox decision as data while
    keeping [lib/exec] independent of [lib/keeper] (the keeper layer
    injects its Docker runtime via the [runner] closure). *)

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

(** Discriminator for telemetry. The actual dispatch logic lives in
    the runner closure, so the kind variant is intentionally narrow. *)
type kind =
  | Host
  | Docker of { image : string }

type t = {
  kind : kind;
  runner : runner;
}

(** Default host runner: forwards directly to
    [Process_eio.run_argv_with_status_split]. *)
val host : unit -> t

(** Build a Docker target. The caller (typically [lib/keeper]) supplies
    the runner closure; this keeps [lib/exec] from having to know about
    [Keeper_turn_sandbox_runtime] or any other keeper-side construct. *)
val docker : image:string -> runner:runner -> t

val kind : t -> kind

val pp_kind : Format.formatter -> kind -> unit
