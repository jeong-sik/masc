type dispatch_result = {
  status : Unix.process_status;
  stdout : string;
  stderr : string;
}

val resolve_arg : Shell_ir.arg -> string
(** Resolve a Shell_ir.arg to a concrete string value. *)


val dispatch_simple :
  ?base_host_env:string array ->
  ?timeout_sec:float ->
  ?stdin_content:string ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Shell_ir.simple ->
  dispatch_result
(** Execute a simple command via argv-based spawn.  [stdin_content] is
    used by pipeline dispatch when a previous stage's stdout must be
    forwarded without dropping the stage's sandbox target.
    [?on_output_chunk] is invoked for every chunk read from
    stdout/stderr while the process is running on the host sandbox path,
    including host commands that receive typed stdin. Docker runner targets
    receive the same callback contract. *)

val dispatch :
  ?base_host_env:string array ->
  ?timeout_sec:float ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Shell_ir.t ->
  dispatch_result
(** General dispatch over any [Shell_ir.t] variant.  [Simple] routes
    to [dispatch_simple]; [Pipeline] routes to internal pipeline
    logic.  Callers are responsible for structural and path validation at
    their boundary; this module only executes the supplied typed IR. *)

val dispatch_pipeline :
  ?base_host_env:string array ->
  ?timeout_sec:float ->
  ?stdin_content:string ->
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
    stage. *)
