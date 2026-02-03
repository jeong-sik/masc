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

(** {1 Global init (call once from main_eio.ml)} *)

val init :
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit

val get_proc_mgr : unit -> Eio_unix.Process.mgr_ty Eio.Resource.t
val get_clock : unit -> float Eio.Time.clock_ty Eio.Resource.t

(** {1 Eio-native process execution (global refs)} *)

(** Run shell command, capture stdout. Empty on timeout/error.
    @param timeout_sec Timeout in seconds (default: 60.0) *)
val run : ?timeout_sec:float -> string -> string

(** Run command with explicit argv (no shell). Safe from injection.
    @param timeout_sec Timeout in seconds (default: 60.0)
    @since 2.45.0 *)
val run_argv : ?timeout_sec:float -> string list -> string

(** Run command with explicit argv and stdin input (no shell).
    @param timeout_sec Timeout in seconds (default: 60.0)
    @param stdin_content Body piped to process stdin
    @since 2.45.0 *)
val run_argv_with_stdin : ?timeout_sec:float -> stdin_content:string -> string list -> string

(** Run shell command, return (Unix.process_status, stdout).
    On timeout returns (WSIGNALED sigterm, partial_output).
    @param timeout_sec Timeout in seconds (default: 60.0) *)
val run_with_status : ?timeout_sec:float -> string -> (Unix.process_status * string)
