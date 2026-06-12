(** A4a — production spawn wrappers around [Process_eio].

    The [run_argv*] helpers are the production entry points used by the
    cutover callers.  They delegate directly to [Process_eio]; the
    [MASC_EXEC_GATE] approval gate that once wrapped them defaulted to
    off and was never enabled outside its test, so the verdict
    computation (and the [run] dispatcher / [error] type it fed) has
    been removed (see exec_gate.ml history note). The
    [~actor]/[~raw_source]/[~summary] arguments are retained for
    signature compatibility but are no longer consumed. *)

val run_argv :
  actor:Agent_id.t ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?env:string array ->
  string list ->
  string
(** Delegates to [Process_eio.run_argv]. *)

val run_argv_with_status :
  actor:Agent_id.t ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  string list ->
  (Unix.process_status * string)
(** Delegates to [Process_eio.run_argv_with_status]. *)

val run_argv_with_status_split :
  actor:Agent_id.t ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  string list ->
  (Unix.process_status * string * string)
(** Delegates to [Process_eio.run_argv_with_status_split]. *)

val run_argv_with_status_split_streaming :
  actor:Agent_id.t ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  on_stdout_chunk:(string -> unit) ->
  on_stderr_chunk:(string -> unit) ->
  string list ->
  (Unix.process_status * string * string)
(** Delegates to [Process_eio.run_argv_with_status_split_streaming]. *)

val run_argv_with_stdin_and_status :
  actor:Agent_id.t ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  stdin_content:string ->
  string list ->
  (Unix.process_status * string)
(** Delegates to [Process_eio.run_argv_with_stdin_and_status]. *)

val run_argv_with_stdin_and_status_split :
  actor:Agent_id.t ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  stdin_content:string ->
  string list ->
  (Unix.process_status * string * string)
(** Delegates to [Process_eio.run_argv_with_stdin_and_status_split]. *)

val run_argv_pipeline_with_status_split :
  actor:Agent_id.t ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  Process_eio.pipeline_stage list ->
  (Unix.process_status * string * string)
(** Delegates to [Process_eio.run_argv_pipeline_with_status_split]. *)
