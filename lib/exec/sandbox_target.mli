(** Sandbox target abstraction consumed by the Shell_ir dispatch path.

    See [sandbox_target.ml] for the rationale. The short version: this
    type lets [Shell_ir.simple] carry the sandbox decision as data while
    keeping [lib/exec] independent of [lib/keeper] (the keeper layer
    injects its Docker or SSH runtime via the [runner] closure).

    [t] is a variant rather than a record so that the [Host] case needs
    no runner.  The dispatch path in [Exec_dispatch] routes [Host]
    directly to [Process_eio], and guest / SSH targets via the carried
    [runner]. *)

(** What kind of transport failure it was. *)
type transport_failure =
  | Payload_timed_out
      (** The payload ran past its time budget and the endpoint stopped it
          (the remote shim's [timed_out]). A host-side budget that ran out
          before the endpoint answered is a stalled lane, not this. *)
  | Lane_unavailable
      (** The lane never delivered the command's own result: unreachable
          endpoint, refused request, unreadable reply, or a lane that cannot
          run this request. *)

(** The status a caller that needs one gives a transport failure: a timeout
    is {!Process_eio.timed_out_status}, the status a host run that timed out
    has, so a remote timeout is read as a timeout wherever a host one is; an
    unavailable lane is [WEXITED 1]. *)
val status_of_transport_failure : transport_failure -> Unix.process_status

(** Whether a runner delivered the command's own result ([Ran]), or the
    transport failed before/instead of producing one ([Transport_failed]).
    The remote lane used to report both as [WEXITED 1], so a lane that was
    down read as grep's real "no match" and Grep returned an empty result
    that never ran. A local docker/host exec has no transport that can fail
    before an exit, so its runner is always [Ran]. *)
type run_outcome =
  | Ran of {
      status : Unix.process_status;
      stdout : string;
      stderr : string;
      output_files : Process_output_capture.files option;
    }
  | Transport_failed of {
      failure : transport_failure;
      reason : string;
      stdout : string;
      stderr : string;
      output_files : Process_output_capture.files option;
    }
(** [output_files] names the original stream captures owned by the caller.
    [None] means this producer did not preserve files; captured text alone
    is not evidence that the complete streams were retained. *)

(** Collapse a [run_outcome] to the legacy [status, stdout, stderr] tuple for
    consumers that treat a transport failure the same as any command failure
    ([Transport_failed] becomes {!status_of_transport_failure}). Do NOT use this where a non-zero
    exit can mean success (the read backend's Grep lane): match the variant
    directly there so a down lane cannot read as an empty result. *)
val status_tuple : run_outcome -> Unix.process_status * string * string

(** A runner closure executes an argv with the given env / cwd and returns a
    [run_outcome]. Exceptions are propagated; callers in [Exec_dispatch] catch
    and translate them into structured dispatch results. *)
type runner =
  on_stdout_chunk:(string -> unit) option ->
  on_stderr_chunk:(string -> unit) option ->
  stdin_content:string option ->
  argv:string list ->
  env:string array ->
  cwd:string option ->
  run_outcome

type pipeline_stage = {
  argv : string list;
  env : string array;
  cwd : string option;
}

type pipeline_runner =
  on_stdout_chunk:(string -> unit) option ->
  on_stderr_chunk:(string -> unit) option ->
  stages:pipeline_stage list ->
  run_outcome

(** SSH endpoint identity carried by an [Ssh] target.  Deliberately a
    standalone record, not [Exec_ssh_endpoint.t]: [lib/exec] stays
    dependency-clean and the keeper layer converts its config-layer record
    into this one at target construction.  [max_concurrent_sessions] and
    [capabilities] are keeper-side runner/preflight concerns and stay out. *)
type ssh_endpoint = {
  name : string;
  host : string;
  user : string;
  port : int;
  identity_file : string;
  known_hosts_file : string;
  remote_root : string;
  connect_timeout_sec : int;
  env_allowlist : string list;
  allowed_paths : string list;
      (** Extra endpoint-side roots an Execute command on this endpoint may
          name, beyond the keeper workdir and [/tmp].  Absolute and
          normalized (the config parser refuses anything else); the path
          check compares them lexically, never through the host
          filesystem. *)
}

type t =
  | Host
  | Docker of { image : string; runner : runner; pipeline_runner : pipeline_runner option }
  | Micro_vm of { image : string; runner : runner; pipeline_runner : pipeline_runner option }
  | Ssh of { endpoint : ssh_endpoint; runner : runner; pipeline_runner : pipeline_runner option }
  | Delegated of { caller : runner }
      (** A stage that is not a process at all: the [caller] decides what
          the argv means and returns a process-shaped answer (status,
          stdout, stderr).  [lib/exec] stays product-neutral — what the
          caller does with the argv (run a catalog tool, answer from a
          fixture) is the caller's layer.  RFC tools-as-shell-commands. *)

(** Default host target.  The dispatch path routes this directly to
    [Process_eio]; no runner is carried. *)
val host : unit -> t

(** Build a delegated target.  The caller owns the interpretation of the
    argv; dispatch only requires the answer to be process-shaped. *)
val delegated : caller:runner -> unit -> t

(** Build a Docker target.  The caller (typically [lib/keeper]) supplies
    the runner closure; this keeps [lib/exec] from having to know about
    [Keeper_turn_sandbox_runtime] or any other keeper-side construct. *)
val docker : image:string -> runner:runner -> ?pipeline_runner:pipeline_runner -> unit -> t

(** Build an Apple Container microVM target. The runner owns guest startup and
    command execution; keeping this distinct from [Docker] prevents policy and
    telemetry consumers from reporting the wrong backend. *)
val micro_vm : image:string -> runner:runner -> ?pipeline_runner:pipeline_runner -> unit -> t

(** Build an SSH target.  As with {!docker}, the caller (the keeper layer)
    supplies the runner closure over its own SSH runtime; [lib/exec] only
    sees the [endpoint] as data for labeling and the shape of the closure. *)
val ssh : endpoint:ssh_endpoint -> runner:runner -> ?pipeline_runner:pipeline_runner -> unit -> t
