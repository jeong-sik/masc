(** Sandbox target abstraction consumed by the Shell_ir dispatch path.

    See [sandbox_target.ml] for the rationale. The short version: this
    type lets [Shell_ir.simple] carry the sandbox decision as data while
    keeping [lib/exec] independent of [lib/keeper] (the keeper layer
    injects its Docker runtime via the [runner] closure).

    [t] is a variant rather than a record so that the [Host] case needs
    no runner.  The dispatch path in [Exec_dispatch] routes [Host]
    directly to [Exec_gate], avoiding a circular dependency between
    [Sandbox_target] and [Exec_gate]. *)

(** A resolved environment binding. Keeping the key and value structured
    prevents sandbox backends from reparsing ["K=V"] strings or accepting
    Docker's bare-key host-environment import form. *)
type env_binding =
  { key : string
  ; value : string
  }

(** A runner closure executes an argv with the given env / cwd and returns
    the raw process status plus stdout/stderr buffers. Exceptions are
    propagated; callers in [Exec_dispatch] catch and translate them into
    structured dispatch results. *)
type runner =
  on_stdout_chunk:(string -> unit) option ->
  on_stderr_chunk:(string -> unit) option ->
  stdin_content:string option ->
  argv:string list ->
  env:env_binding array ->
  cwd:string option ->
  Unix.process_status * string * string

type pipeline_stage = {
  argv : string list;
  env : env_binding array;
  cwd : string option;
}

type pipeline_runner =
  on_stdout_chunk:(string -> unit) option ->
  on_stderr_chunk:(string -> unit) option ->
  stages:pipeline_stage list ->
  Unix.process_status * string * string

type t =
  | Host
  | Docker of { image : string; runner : runner; pipeline_runner : pipeline_runner option }

(** Default host target.  The dispatch path routes this directly to
    [Exec_gate]; no runner is carried. *)
val host : unit -> t

(** Build a Docker target.  The caller (typically [lib/keeper]) supplies
    the runner closure; this keeps [lib/exec] from having to know about
    [Keeper_turn_sandbox_runtime] or any other keeper-side construct. *)
val docker : image:string -> runner:runner -> ?pipeline_runner:pipeline_runner -> unit -> t
