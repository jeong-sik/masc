(** Async process execution helpers for Eio *)

val run_capture_stdout :
  sw:Eio.Switch.t ->
  proc_mgr:[> [> `Generic ] Eio.Process.mgr_ty ] Eio.Resource.t ->
  clock:_ Eio.Time.clock ->
  ?timeout_sec:float ->
  string ->
  string

val run_capture_stdout_with_clock :
  sw:Eio.Switch.t ->
  proc_mgr:[> [> `Generic ] Eio.Process.mgr_ty ] Eio.Resource.t ->
  clock:_ Eio.Time.clock ->
  ?timeout_sec:float ->
  string ->
  string

val run_status :
  sw:Eio.Switch.t ->
  proc_mgr:[> [> `Generic ] Eio.Process.mgr_ty ] Eio.Resource.t ->
  clock:_ Eio.Time.clock ->
  ?timeout_sec:float ->
  string ->
  bool

val run_with_stdin :
  sw:Eio.Switch.t ->
  proc_mgr:[> [> `Generic ] Eio.Process.mgr_ty ] Eio.Resource.t ->
  clock:_ Eio.Time.clock ->
  ?timeout_sec:float ->
  stdin_content:string ->
  string ->
  string

val read_all_lines :
  sw:Eio.Switch.t ->
  proc_mgr:[> [> `Generic ] Eio.Process.mgr_ty ] Eio.Resource.t ->
  clock:_ Eio.Time.clock ->
  ?timeout_sec:float ->
  string ->
  string list

val run_detached :
  sw:Eio.Switch.t ->
  proc_mgr:[> [> `Generic ] Eio.Process.mgr_ty ] Eio.Resource.t ->
  string ->
  unit

(** {1 Systhread variants (no proc_mgr needed)} *)

(** Run shell command in a system thread with timeout.
    Non-blocking to Eio event loop.
    Returns stdout as string, empty on timeout/error.
    @param timeout_sec Timeout in seconds (default: 60.0) *)
val run_in_systhread : ?timeout_sec:float -> string -> string

(** Run shell command in a system thread with timeout.
    Non-blocking to Eio event loop.
    Returns (Unix.process_status, stdout).
    On timeout returns (WSIGNALED sigterm, partial_output).
    @param timeout_sec Timeout in seconds (default: 60.0) *)
val run_in_systhread_with_status : ?timeout_sec:float -> string -> (Unix.process_status * string)
