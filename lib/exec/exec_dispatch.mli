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
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Shell_ir.t ->
  dispatch_result
(** General dispatch over any [Shell_ir.t] variant.  [Simple] routes
    to [dispatch_simple]; [Pipeline] routes to internal pipeline
    logic.  Prefer [dispatch_decided] for production keeper paths.
    Exposed for tests and legacy call sites. *)

val dispatch_decided :
  ?base_host_env:string array ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Shell_ir_risk.decided Shell_ir_risk.decided_ir ->
  dispatch_result
(** RFC-0160 S3: dispatch a risk-classified IR.  The phantom type
    ensures the IR has passed through [Shell_ir_risk.classify]. *)

val dispatch_async :
  ?base_host_env:string array ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  sw:Eio.Switch.t ->
  Shell_ir_risk.decided Shell_ir_risk.decided_ir ->
  dispatch_result Eio.Promise.t
(** Start a classified Shell IR dispatch in a new fiber and return a
    promise for its result. Cancellation of [sw] propagates to the
    forked fiber; successful completion resolves the promise with the
    {!dispatch_result}. *)

type dispatch_outcome = {
  status : Unix.process_status;
  stdout : string;
  stderr : string;
  semantic : Exec_semantic.t;
}
(** Structured dispatch result that carries a post-execution semantic
    classification alongside raw status and captured output. *)

val dispatch_decided_outcome :
  ?base_host_env:string array ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Shell_ir_risk.decided Shell_ir_risk.decided_ir ->
  dispatch_outcome
(** Like {!dispatch_decided}, but returns a {!dispatch_outcome} with
    [Exec_semantic.interpret] applied to the result. The semantic class
    is derived from the executed command's argv, exit status, and
    captured output. *)

val dispatch_pipeline :
  ?base_host_env:string array ->
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
