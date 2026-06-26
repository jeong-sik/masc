(** RFC-0109 — Bounded subprocess discipline.

    Run a single subprocess with a hard monotonic-time bound and capture
    stdout/stderr. The implementation relies on a single Eio invariant
    quoted from
    https://ocaml.org/p/eio/latest/doc/Eio/Process/index.html:

    {v "The child process will be sent Sys.sigkill when the switch is
       released." v}

    A fresh [Eio.Switch.run] scope is opened inside the helper, so the
    subprocess lifetime is decoupled from any long-lived caller switch.
    When the timeout fiber wins the {!Eio.Fiber.first} race, the inner
    switch ends and the kernel kills the process unconditionally — no
    SIGTERM grace period, no Cancel propagation requirement. C-blocking
    [Eio.Process.await] does not honour Eio cancellation by design
    (see https://ocaml.org/p/eio/latest/doc/Eio/Cancel/index.html),
    which is why scope termination is the only reliable termination
    primitive available. *)

(** Diagnostic payload returned when a subprocess exceeds its bound. *)
type timeout =
  { argv : string list
        (** Exact argv passed to {!run_argv_with_timeout}. *)
  ; timeout_s : float
        (** Requested timeout budget in seconds. *)
  ; elapsed_s : float
        (** Elapsed monotonic time in seconds. *)
  ; stdout : string
        (** Partial stdout captured before the timeout won the race. *)
  ; stderr : string
        (** Partial stderr captured before the timeout won the race. *)
  }

(** Outcome of {!run_argv_with_timeout}. *)
type outcome =
  | Done of Unix.process_status * string * string
      (** Process finished within the timeout. Fields are
          [(status, stdout, stderr)]. *)
  | Timeout of timeout
      (** Timeout fiber won the race. Carries the requested argv, timeout
          budget, monotonic elapsed time, and partial captured output. The
          subprocess has been SIGKILLed by Eio at the point this constructor is
          observed. *)

val run_argv_with_timeout :
  mono_clock:_ Eio.Time.Mono.t ->
  process_mgr:_ Eio.Process.mgr ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?env:string array ->
  ?stdin_string:string ->
  timeout_s:float ->
  string list ->
  outcome
(** [run_argv_with_timeout ~mono_clock ~process_mgr ~cwd ?env ?stdin_string
    ~timeout_s argv] spawns [argv] under a fresh internal switch and
    races the call against [Eio.Time.Mono.sleep mono_clock timeout_s].

    Returns {!Done} with the captured stdout/stderr if the process
    finishes first, or {!Timeout} otherwise.

    {b Invariants}:
    - On {!Timeout}, the subprocess is guaranteed to be SIGKILLed by
      the time this function returns (Eio.Process spec).
    - The caller's ambient switch is not used for spawn — process
      lifetime is bounded by [timeout_s], not by the caller.
    - [stdin_string], when given, is wrapped in
      {!Eio.Flow.string_source} and connected to the child's stdin.

    Use this helper at any boundary that spawns an external process
    whose runtime cannot be trusted to honour Eio cancellation (LLM
    HTTPS clients, [docker exec]/[docker run], git/gh, ...). *)
