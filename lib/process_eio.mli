(** Async process execution helpers for Eio *)

val run_capture_stdout :
  sw:Eio.Switch.t ->
  proc_mgr:[> [> `Generic ] Eio.Process.mgr_ty ] Eio.Resource.t ->
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
