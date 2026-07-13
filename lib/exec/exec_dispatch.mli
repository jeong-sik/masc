type dispatch_result = {
  status : Unix.process_status;
  stdout : string;
  stderr : string;
}

val resolve_arg : Shell_ir.arg -> string
(** Resolve a Shell_ir.arg to a concrete string value. *)


val dispatch_simple :
  ?base_host_env:string array ->
  ?stdin_content:string ->
  ?timeout_sec:float ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Shell_ir.simple ->
  dispatch_result
(** Execute a simple command via argv-based spawn.  [stdin_content] is
    used by pipeline dispatch when a previous stage's stdout must be
    forwarded without dropping the stage's sandbox target.
    [?on_output_chunk] is invoked for every chunk read from
    stdout/stderr while the process is running on the host sandbox path,
    including host commands that receive typed stdin. Docker runner targets
    receive the same callback contract.  [?timeout_sec], when supplied, is
    forwarded to [Exec_gate] on the [Host] sandbox path only; absent, the
    call keeps [Exec_gate]'s existing default timeout.  The [Docker] path
    ignores it — [Sandbox_target.runner] has no timeout parameter yet. *)

val dispatch :
  ?base_host_env:string array ->
  ?timeout_sec:float ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Shell_ir.t ->
  dispatch_result
(** General dispatch over any [Shell_ir.t] variant.  [Simple] routes
    to [dispatch_simple]; [Pipeline] routes to internal pipeline
    logic.  Prefer [dispatch_decided] for production keeper paths.
    Exposed for tests and legacy call sites.  [?timeout_sec] is forwarded
    unchanged; see [dispatch_simple] for the Host/Docker caveat. *)

val dispatch_decided :
  ?base_host_env:string array ->
  ?timeout_sec:float ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Shell_ir_risk.decided Shell_ir_risk.decided_ir ->
  dispatch_result
(** RFC-0160 S3: dispatch a risk-classified IR.  The phantom type
    ensures the IR has passed through [Shell_ir_risk.classify].
    [?timeout_sec] is forwarded unchanged to [dispatch]. *)

val dispatch_pipeline :
  ?base_host_env:string array ->
  ?stdin_content:string ->
  ?timeout_sec:float ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Shell_ir.t list ->
  dispatch_result
(** Execute a pipeline of commands, streaming stdout between stages.
    Handles [Simple] stages natively; nested [Pipeline] stages are
    rejected with an error.  [?on_output_chunk] is invoked for chunks read
    from the host native pipeline's final stdout and per-stage stderr pipes
    while the pipeline is still running. Docker pipeline runners receive the
    same callback contract. Decomposed fallback pipeline paths stream each
    stage's stderr and the final stage's stdout through the same callback
    contract while preserving intermediate stdout as stdin for the next
    stage.

    [?timeout_sec] semantics are path-dependent, not uniform:
    - Host native pipeline (every stage [Host] sandbox with no redirects,
      per [host_pipeline_specs]): forwarded to
      [Exec_gate.run_argv_pipeline_with_status_split], which wraps the
      *entire* pipeline await in a single
      [Eio.Time.with_timeout_exn] — one deadline for the whole pipeline,
      not per stage (see [Process_eio.run_argv_pipeline_with_status_split]).
    - Decomposed fallback (mixed sandboxes, any stage with redirects, or no
      matching Docker [pipeline_runner]): each stage is dispatched in turn
      via [dispatch_simple ?timeout_sec], so the deadline resets per stage;
      worst-case total wall time is [List.length stages * timeout_sec].
    - Docker [pipeline_runner] path: ignores [?timeout_sec] entirely —
      [Sandbox_target.pipeline_runner] has no timeout parameter yet. *)
