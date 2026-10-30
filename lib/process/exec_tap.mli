(** Exec tap — RFC v5 Phase T0 observational shim.

    Records each Process_eio exec invocation as a JSONL line
    when enabled.  No-op (identity passthrough) when disabled.  Default OFF.

    Purpose: empirical inventory of LLM-generated exec patterns for the
    downstream typed IR design (Bash subset + Capability variants).

    Boot: call {!install_from_env} once from [bin/main_eio.ml].  Reads
    [MASC_EXEC_TAP=1] to enable, [MASC_EXEC_TAP_OUT] for the output path
    (default [audits/exec-corpus.jsonl]).  Records are line-atomic up to
    PIPE_BUF; very long argvs may interleave on concurrent writers.

    @since RFC v5 T0 *)

(** The [Process_eio] wrapper that ran the exec.  The report generator
    counts records per kind. *)
type call_kind =
  | Process_eio_run_argv
  | Process_eio_run_argv_with_stdin
  | Process_eio_run_argv_with_stdin_and_status
  | Process_eio_run_argv_with_status

(** Observed process boundaries. These events never decide timeout,
    cancellation, retry or ownership. Spawn argv uses the existing redactor. *)
type lifecycle_stage =
  | Spawned of string list
  | Waitpid_started
  | Waitpid_returned
  | Exit_published
  | Stdout_closed
  | Stderr_closed
  | Awaiting_exit
  | Exit_observed

val record_lifecycle : pid:int -> stage:lifecycle_stage -> unit -> unit
(** Emit [kind=Process.lifecycle] through the same opt-in writer, with the
    actual child PID and closed stage. Default OFF. A stage record is not an
    exec invocation and must not be counted as one by corpus consumers. *)

(** {1 Control} *)

val enable : writer:(string -> unit) -> unit
(** Enable the tap.  [writer] is invoked per exec call or lifecycle observation with a complete
    JSONL line (trailing newline included).  Subsequent [enable] calls
    replace the writer.  Thread-safe. *)

val disable : unit -> unit

val enabled : unit -> bool

val install_from_env : unit -> unit
(** If [MASC_EXEC_TAP] is truthy ([1]/[true]/[yes]), open the output file
    at [MASC_EXEC_TAP_OUT] (default [audits/exec-corpus.jsonl]) for append
    and install a line-atomic writer.  No-op otherwise.  Safe to call
    multiple times — later calls replace the writer. *)

(** {1 Recording} *)

val record :
  kind:call_kind ->
  argv:string list ->
  ?env:string array ->
  ?cwd:string ->
  unit ->
  unit
(** Emit one JSONL line when enabled, no-op otherwise.  [env] is reduced
    to its keys (values stripped — avoids secret leakage).  [cwd] is the
    caller-provided working directory, not the process cwd. *)

(** Emit one JSONL line describing an exec-gate decision.  This is
    separate from the eventual [Process_eio.*] spawn record so shadow
    mode can publish verdict evidence without mutating the actual spawn
    path or double-counting spawns in downstream reports. *)
