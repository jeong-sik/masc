(* Sandbox target abstraction for Shell_ir dispatch.

   Why this exists
   ---------------
   Prior to 2026-04-28, [Exec_dispatch.dispatch_simple] called
   [Process_eio.run_argv_with_status_split] directly. The Shell_ir record
   carried no information about *where* the command should run, so every
   parsed shell command short-circuited to a host-side fork/exec. When a
   keeper was configured for [sandbox_profile = "docker"], the keeper's
   bash dispatch path consulted [Keeper_shell_docker.run_docker_*]
   functions, but any command that flowed through the Shell_ir IR
   bypassed that branch entirely (defect A in the 2026-04-28 root-fix
   audit).

   This module introduces a callback-runner abstraction that lets
   Shell_ir carry the sandbox decision *as data*, while keeping the
   layering clean: [lib/exec] cannot depend on [lib/keeper], so we do
   not embed [Keeper_turn_sandbox_runtime.t] in the kind. Instead, the
   keeper layer constructs a [t] whose [runner] is a closure over its
   own runtime; [lib/exec] only sees the shape of the closure.

   Usage shape
   -----------
   - Host: build via [host ()]; runs the argv in a host process via
     [Process_eio.run_argv_with_status_split].
   - Docker: built by [lib/keeper] (e.g.,
     [Keeper_shell_docker.sandbox_target_of_runtime]) and embedded in
     the [Shell_ir.simple] record before dispatch. The runner closure
     adapts the keeper-side Docker call into the same callback shape.

   Status (2026-04-28)
   -------------------
   Step 1 of PR-2: this module is introduced ahead of the cascade
   change in [Shell_ir.simple]. The dispatch path in
   [Exec_dispatch.dispatch_simple] does not consume the type yet —
   that wiring lands in step 2 once the cascade sites in tests and
   library callers are converted. *)

type runner =
  argv:string list ->
  env:string array ->
  cwd:string option ->
  timeout_sec:float ->
  Unix.process_status * string * string

(** [kind] is a structural tag for telemetry and logging. The runner
    closure carries the actual dispatch logic, so this tag does not
    need to enumerate every concrete runtime — it is a discriminator,
    not a state machine. *)
type kind =
  | Host
  | Docker of { image : string }

type t = {
  kind : kind;
  runner : runner;
}

(** Default host runner: forwards to [Process_eio.run_argv_with_status_split].
    Exceptions raised by the underlying runner are propagated unchanged so
    callers can decide whether to translate them into structured errors.
    The previous behavior (in [Exec_dispatch.dispatch_simple]) was to
    catch and surface them via the dispatch result; this preserves the
    same call shape so wiring step 2 is a structural rename, not a
    semantic shift. *)
let host () : t =
  let runner ~argv ~env ~cwd ~timeout_sec =
    Process_eio.run_argv_with_status_split ~timeout_sec ~env ?cwd argv
  in
  { kind = Host; runner }

(** Build a Docker target from a caller-supplied runner closure. Used by
    [lib/keeper] to inject [Keeper_turn_sandbox_runtime] without the
    [lib/exec] layer taking a dependency on [lib/keeper]. *)
let docker ~image ~runner : t =
  { kind = Docker { image }; runner }

let kind t = t.kind

let pp_kind fmt = function
  | Host -> Format.pp_print_string fmt "host"
  | Docker { image } -> Format.fprintf fmt "docker(%s)" image
