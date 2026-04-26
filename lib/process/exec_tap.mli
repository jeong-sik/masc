(** Exec tap — RFC v5 Phase T0 observational shim.

    Records each Process_eio / Unix.* exec invocation as a JSONL line
    when enabled.  No-op (identity passthrough) when disabled.  Default OFF.

    Purpose: empirical inventory of LLM-generated exec patterns for the
    downstream typed IR design (Bash subset + Capability variants).

    Boot: call {!install_from_env} once from [bin/main_eio.ml].  Reads
    [MASC_EXEC_TAP=1] to enable, [MASC_EXEC_TAP_OUT] for the output path
    (default [audits/exec-corpus.jsonl]).  Records are line-atomic up to
    PIPE_BUF; very long argvs may interleave on concurrent writers.

    @since RFC v5 T0 *)

(** Source of an exec call.  Report generator uses this to distinguish
    Process_eio wrappers from direct Unix.* callsites. *)
type call_kind =
  | Exec_gate_decision
  | Process_eio_run_argv
  | Process_eio_run_argv_with_stdin
  | Process_eio_run_argv_with_stdin_and_status
  | Process_eio_run_argv_with_status
  | Unix_create_process
  | Unix_create_process_env
  | Unix_open_process_args_in
  | Unix_open_process_args_full

val kind_to_string : call_kind -> string

(** {1 Control} *)

(** Enable the tap.  [writer] is invoked once per exec call with a complete
    JSONL line (trailing newline included).  Subsequent [enable] calls
    replace the writer.  Thread-safe. *)
val enable : writer:(string -> unit) -> unit

val disable : unit -> unit
val enabled : unit -> bool

(** If [MASC_EXEC_TAP] is truthy ([1]/[true]/[yes]), open the output file
    at [MASC_EXEC_TAP_OUT] (default [audits/exec-corpus.jsonl]) for append
    and install a line-atomic writer.  No-op otherwise.  Safe to call
    multiple times — later calls replace the writer. *)
val install_from_env : unit -> unit

(** {1 Recording} *)

(** Emit one JSONL line when enabled, no-op otherwise.  [env] is reduced
    to its keys (values stripped — avoids secret leakage).  [cwd] is the
    caller-provided working directory, not the process cwd. *)
val record
  :  kind:call_kind
  -> argv:string list
  -> ?env:string array
  -> ?cwd:string
  -> unit
  -> unit

(** Emit one JSONL line describing an exec-gate decision.  This is
    separate from the eventual [Process_eio.*] spawn record so shadow
    mode can publish verdict evidence without mutating the actual spawn
    path or double-counting spawns in downstream reports. *)
val record_gate_decision
  :  actor:string
  -> raw_source:string
  -> summary:string
  -> gate_mode:string
  -> gate_verdict:string
  -> gate_enforced:bool
  -> argv:string list
  -> ?env:string array
  -> ?cwd:string
  -> unit
  -> unit
