(** Eio foreground capture effects, independent of runtime initialization and
    caller error/timeout policy. Pipe draining, child cleanup and capture EOF
    have one owner shared by single commands, redirects and pipelines. *)

val child_exit_grace_seconds : float
(** Existing TERM grace shared with the foreground process-group manager. *)

val unix_status_of_eio_status : Eio.Process.exit_status -> Unix.process_status

val is_downstream_pipe_closed : exn -> bool

val invoke_output_chunk_callback : (string -> unit) -> string -> unit
(** Callback failures are logged; cancellation is re-raised. *)

val reap_proc_with_clock :
  sw:Eio.Switch.t -> float Eio.Time.clock_ty Eio.Resource.t ->
  _ Eio.Process.t -> unit
(** TERM then bounded grace and KILL. When the owning switch is cancelled,
    its reap daemon, or its release hook if the daemon failed, owns the final
    reap. *)

val finalize_spawned_proc :
  sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t ->
  _ Eio.Process.t -> Eio.Process.exit_status option ref ->
  sinks:(string * [> Eio.Resource.close_ty] Eio.Resource.t) list ->
  sources:(string * [> Eio.Flow.source_ty | Eio.Resource.close_ty] Eio.Resource.t) list ->
  unit
(** Close parent stdin first. A completed child only needs flow closure;
    ordinary failure reaps it; cancelled-switch cleanup sends TERM and waits,
    within the grace, for the switch's reap daemon to settle the child before
    closing output flows. *)

val drain_to_eof :
  ?file_capture:Process_output_capture.t * Process_output_capture.stream ->
  ?on_chunk:(string -> unit) ->
  [> Eio.Flow.source_ty | Eio.Resource.close_ty] Eio.Resource.t ->
  Exec_buffer.t -> unit
(** Drain to EOF even beyond preview retention, preserving raw capture and
    invoking callbacks before adding each chunk to the preview. Mark capture
    complete only at EOF, then close the reader. *)

val child_input :
  sw:Eio.Switch.t -> Eio.Flow.source_ty Eio.Resource.t option ->
  Eio.Flow.source_ty Eio.Resource.t
(** The flow a child reads as stdin: the given source, or with none an input
    already at its end. Eio's own default is this process's stdin, so a pipe
    or file the server holds there would reach every child it runs (#46850). *)

val spawn_and_drain_stdout :
  ?phase_ref:Timeout_origin.t ref -> sw:Eio.Switch.t ->
  Eio_unix.Process.mgr_ty Eio.Resource.t -> cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?env:string array -> ?stdin_source:Eio.Flow.source_ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t -> string list ->
  Exec_buffer.t -> Unix.process_status

val spawn_and_drain_both :
  ?phase_ref:Timeout_origin.t ref -> ?output_capture:Process_output_capture.t ->
  sw:Eio.Switch.t -> Eio_unix.Process.mgr_ty Eio.Resource.t ->
  cwd:Eio.Fs.dir_ty Eio.Path.t -> ?env:string array ->
  ?stdin_source:Eio.Flow.source_ty Eio.Resource.t -> clock:float Eio.Time.clock_ty Eio.Resource.t ->
  string list -> ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) -> Exec_buffer.t -> Exec_buffer.t ->
  Unix.process_status
(** Both streams have one draining fiber each. Optional callbacks use the
    same EOF/capture/cleanup path as ordinary execution. Await follows EOF. *)

val spawn_and_drain_both_with_stdin_held_open :
  ?phase_ref:Timeout_origin.t ref -> sw:Eio.Switch.t ->
  Eio_unix.Process.mgr_ty Eio.Resource.t -> cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?env:string array -> stdin_content:string ->
  clock:float Eio.Time.clock_ty Eio.Resource.t -> string list ->
  ?on_stdout_chunk:(string -> unit) -> ?on_stderr_chunk:(string -> unit) ->
  Exec_buffer.t -> Exec_buffer.t -> Unix.process_status
(** Keep stdin open after writing the request, for protocols where EOF is
    cancellation. Cleanup closes stdin before granting child TERM grace. *)
