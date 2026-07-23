(* Sandbox target abstraction for Shell_ir dispatch.

   Why this exists
   ---------------
   Prior to 2026-04-28, [Exec_dispatch.dispatch_simple] called
   [Process_eio.run_argv_with_status_split] directly. The Shell_ir record
   carried no information about *where* the command should run, so every
   parsed shell command short-circuited to a host-side fork/exec. When a
   keeper was configured for [sandbox_profile = "docker"], the keeper's
   bash dispatch path consulted [Keeper_sandbox_docker.run_docker_*]
   functions, but any command that flowed through the Shell_ir IR
   bypassed that branch entirely (defect A in the 2026-04-28 root-fix
   audit).

   This module introduces a callback-runner abstraction that lets
   Shell_ir carry the sandbox decision *as data*, while keeping the
   layering clean: [lib/exec] cannot depend on [lib/keeper], so we do
   not embed [Keeper_turn_sandbox_runtime.t] in the kind. Instead, the
   keeper layer constructs a [t] whose [runner] is a closure over its
   own runtime; [lib/exec] only sees the shape of the closure.

   [t] is a variant rather than a record so that the [Host] case needs
   no runner closure.  [Exec_dispatch] routes [Host] directly to
   [Exec_gate], and [Docker] via the carried [runner]. *)

type runner =
  on_stdout_chunk:(string -> unit) option ->
  on_stderr_chunk:(string -> unit) option ->
  stdin_content:string option ->
  argv:string list ->
  env:string array ->
  cwd:string option ->
  Unix.process_status * string * string

type pipeline_stage = {
  argv : string list;
  env : string array;
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

let host () : t = Host

let docker ~image ~runner ?pipeline_runner () : t = Docker { image; runner; pipeline_runner }

let pp fmt = function
  | Host -> Format.pp_print_string fmt "host"
  | Docker { image } -> Format.fprintf fmt "docker(%s)" image
