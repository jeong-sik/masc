type dispatch_result = {
  status : Unix.process_status;
  stdout : string;
  stderr : string;
  output_files : Process_output_capture.files option;
}
(** File sources survive only when they describe the returned streams.
    A dispatch that combines or redirects streams without producing matching
    files returns [None], never a file belonging to only one input stream. *)

val resolve_arg : Shell_ir.arg -> string
(** Resolve literal pieces without reading the server environment.
    Raises [Invalid_argument] for unresolved variables and unevaluated
    substitutions. Public dispatch rejects or evaluates such IR before
    executing any command or opening a redirect. *)


val dispatch_simple :
  ?base_host_env:string array ->
  ?timeout_sec:float ->
  ?stdin_content:string ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  ?started:float ->
  Shell_ir.simple ->
  dispatch_result
(** Execute a simple command via argv-based spawn.  [stdin_content] is
    used by pipeline dispatch when a previous stage's stdout must be
    forwarded without dropping the stage's sandbox target.
    [?on_output_chunk] is invoked for every chunk read from
    stdout/stderr while the process is running on the host sandbox path,
    including host commands that receive typed stdin. Guest and SSH runner
    targets receive the same callback contract.

    [?started] is the epoch the timeout budget is debited against. An
    enclosing pipeline or sequence passes its own [started] so every
    substitution child and every stage spends one shared deadline rather
    than a fresh copy of the remaining timeout (RFC
    shell-ir-typed-command-substitution §2.3 item 4); omitted, it defaults
    to now.

    A [Shell_ir.Subst] in the stage's args or env is evaluated first, by
    dispatching the child IR under the stage's own sandbox target and,
    when the child declares no cwd of its own, the stage's cwd; the
    child's stdout — trailing newlines stripped — becomes exactly one argv
    element, with no word splitting or glob (RFC
    shell-ir-typed-command-substitution §2.3). The child reads the same
    [stdin_content] as the parent, and its stderr is streamed through
    [?on_output_chunk] before the parent's own. *)

val dispatch :
  ?base_host_env:string array ->
  ?timeout_sec:float ->
  ?stdin_content:string ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  ?started:float ->
  Shell_ir.t ->
  dispatch_result
(** General dispatch over any [Shell_ir.t] variant.  [Simple] routes
    to [dispatch_simple]; [Pipeline] routes to internal pipeline
    logic.  [?stdin_content] reaches a substitution child — in bash the
    child and the parent share one stdin descriptor and race for it; the
    deterministic reading hands each the same bytes.  [?started]
    propagates one shared timeout deadline through every stage and
    substitution child, exactly as in {!dispatch_simple}.  Callers are
    responsible for structural and path validation at their boundary;
    this module only executes the supplied typed IR.

    Ordering contract: the validated path (gate, then
    [Exec_policy.validate_shell_ir_paths]) runs before any dispatch, so no
    substitution is evaluated before validation.  A caller that bypasses
    validation and calls {!dispatch} directly runs the child effects of a
    [Shell_ir.Subst] before any check could refuse them. *)

val dispatch_pipeline :
  ?base_host_env:string array ->
  ?timeout_sec:float ->
  ?stdin_content:string ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  ?started:float ->
  Shell_ir.t list ->
  dispatch_result
(** Execute a pipeline of commands, streaming stdout between stages.
    Handles [Simple] stages natively; nested [Pipeline] stages are
    rejected with an error.  [?on_output_chunk] is invoked for chunks read
    from the host native pipeline's final stdout and per-stage stderr pipes
    while the pipeline is still running. Guest and SSH pipeline runners
    receive the same callback contract. Decomposed fallback pipeline paths
    stream each stage's stderr and the final stage's stdout through the same
    callback contract while preserving intermediate stdout as stdin for the
    next stage.

    A stage carrying a [Shell_ir.Subst] has its substitution evaluated
    here, before the runners are chosen, so the pipeline stays on the
    streaming runners — the buffered chain has no backpressure and a
    producer like [yes | head -1] would never stop under it. The children's
    stderr is streamed ahead of the pipeline's own and prepended to the
    returned stderr. *)
