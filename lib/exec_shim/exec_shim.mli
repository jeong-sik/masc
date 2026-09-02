(** Core of the [masc-exec-shim] remote execution shim (Phase 1 SSH remote
    execution lane, normative spec:
    docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md §4.2).

    The shim is a tiny synchronous process supervisor that runs on the
    remote Linux host, invoked by sshd as the fixed remote command
    [masc-exec-shim].  It reads ONE framed request from its stdin (decoded
    with {!Exec_ssh_protocol.decode_request}, so the wire format can never
    drift from the keeper-side runner), executes the payload under a
    supervised child, streams the child's stdout/stderr through verbatim,
    and appends a result trailer ({!Exec_ssh_protocol.render_trailer}) to
    its own STDERR, after the child's stderr.

    Design notes:

    - {b No eio.}  The shim is statically linked for Linux (musl); it is a
      single-threaded [Unix.select] loop and stays dependency-minimal
      ([exec_ssh_protocol] + [unix] only).

    - {b Supervision.}  The child is [fork]ed and calls [setsid()], so its
      process-group id equals its pid; the parent reaps by killing the
      {e process group} ([kill (-pid) sig]).  On Linux the child also sets
      [PR_SET_PDEATHSIG = SIGKILL] pre-exec via the C stub, which covers
      the shim itself dying first.  [PR_SET_PDEATHSIG] is Linux-only; on
      other platforms the stub is a no-op and the process-group kill
      policy below is the primary reaper.

    - {b Kill policy.}  {!kill_policy} is a pure decision function mapping
      a trigger to an ordered action list; the supervision loop merely
      interprets it, so the SIGTERM → grace → SIGKILL escalation is unit
      tested without real signals.

    - {b Trailer and exit codes.}  On a shim-level failure (undecodable
      frame, config problem, jail violation) the shim appends a trailer
      whose [shim_error] is set and exits [1] — never [0], so a shim
      failure can never masquerade as a payload success.  When the
      payload was supervised to completion (exit, signal, or timeout
      kill), the shim appends the trailer and exits [0]; the trailer
      carries the payload outcome.

    {b Shim error codes} (the [shim_error] string always starts with one
    of these, or with a codec error code from [Exec_ssh_protocol]):
    - [remote_ssh_path_jail_violation] — requested cwd escapes the
      configured jail root (or cannot be resolved);
    - [remote_ssh_shim_config_error] — config file absent, unparseable, or
      invalid;
    - [remote_ssh_shim_error] — other shim-internal failures (e.g. empty
      argv, fork failure). *)

(** {1 Environment synthesis}

    The payload's environment is synthesized server-side: a documented
    minimal base env ({!default_base_path} for [PATH]; [HOME], [USER],
    [TMPDIR] taken from the shim's own environment when present, else the
    defaults [/tmp], ["masc"], [/tmp]) overlaid with the endpoint-allowlisted
    request entries and the runner-owned [GH_CONFIG_DIR] and
    [GIT_TERMINAL_PROMPT] entries.  A reserved-name denylist is NEVER accepted
    from the wire — the denylist beats both allowlists. *)

val default_base_path : string
(** [= "/usr/local/bin:/usr/bin:/bin"].  The payload's [PATH] unless the
    endpoint's config names one ([path=], see {!config}); the wire can never
    influence it. *)

val default_payload_path : string list
(** {!default_base_path} split on [:]. *)

val denylisted_env_name : string -> bool
(** [true] for names never accepted from the wire: [PATH], [HOME],
    [LD_PRELOAD], [LD_LIBRARY_PATH], [BASH_ENV], [ENV], and every name
    with the [DYLD_] prefix.  Matching is case-sensitive; [PATH] from the
    wire is dropped even when it appears in the endpoint allowlist. *)

val synthesize_env :
  path:string ->
  base_env:(string * string) list ->
  allowlist:string list ->
  request_env:(string * string) list ->
  (string * string) list
(** [synthesize_env ~base_env ~allowlist ~request_env] is the payload's
    full environment: the minimal base env (see above; [base_env] is the
    shim's own process environment — the function itself is pure and performs
    no process-state lookups; [path] is the payload [PATH], the endpoint
    config's [payload_path] joined on [:])
    with each non-denylisted request entry overlaid
    when its name is in [allowlist] or is one of the runner-owned
    [GH_CONFIG_DIR] and [GIT_TERMINAL_PROMPT] names.  A request entry whose
    name collides with a base key replaces the base value.  Duplicate names in
    [request_env] are last-wins.  The result has unique keys; order is
    unspecified. *)

(** {1 Kill policy} *)

val kill_grace_sec : float
(** [= 2.0].  Grace between SIGTERM and SIGKILL to the payload's process
    group. *)

type kill_trigger =
  | On_eof  (** shim stdin reached EOF (ssh channel closed/cancelled) *)
  | On_timeout  (** [timeout_sec] wall-clock budget expired *)
  | On_child_exit  (** payload process reaped; reap leftover group members *)

type kill_action =
  | Sigterm_pgid  (** send SIGTERM to the payload's process group *)
  | Wait_grace of float  (** wait this many seconds before the next action *)
  | Sigkill_pgid  (** send SIGKILL to the payload's process group *)

val kill_policy : ?grace_sec:float -> kill_trigger -> kill_action list
(** Pure decision function, asserted by unit tests (no real signals):
    - [On_eof] and [On_timeout] →
      [[Sigterm_pgid; Wait_grace grace; Sigkill_pgid]] — no remote
      orphans, including for quiet payloads such as [sleep 600];
    - [On_child_exit] → [[Sigkill_pgid]] — the payload itself is already
      reaped; a final SIGKILL to the group reaps grandchildren that
      inherited its pipes/session (a no-op when the group is gone). *)

(** {1 Waitpid status → trailer} *)

val host_signal_number : int -> int
(** Converts an OCaml abstract signal code ([Sys.sig*] constants and the
    signal reported by [Unix.WSIGNALED] are portable codes, {e not} host
    OS signal numbers) to the host OS signal number, via the runtime's
    own conversion table.  [host_signal_number Sys.sigkill = 9] and
    [host_signal_number Sys.sigterm = 15] on Linux and macOS. *)

val trailer_of_status :
  timed_out:bool -> Unix.process_status -> Exec_ssh_protocol.trailer
(** Maps a reaped child status to the result trailer: [WEXITED n] →
    [exit = Some n], [WSIGNALED n] → [signal = Some] of the {b host OS}
    signal number (via {!host_signal_number} — the wire must carry 9 or
    15, never OCaml's abstract codes).  ([WSTOPPED] cannot occur: the
    shim never passes [WUNTRACED] to [waitpid]; it is mapped like
    [WSIGNALED] defensively.)  The result always satisfies the codec's
    trailer invariants (exactly one of [exit]/[signal] set,
    [shim_error = None]). *)

(** {1 Server-side path jail}

    Defense in depth: the runner-side gate is layer 1, the shim
    re-applies the jail without trusting the wire.  The jail root comes
    from a local config file, never from the request. *)

val jail_error_code : string
(** [= "remote_ssh_path_jail_violation"]. *)

(** [Ok ()] iff [cwd] — after [realpath] normalization of both paths —
    equals [root] or is a descendant of it (component-boundary aware).
    [Error] carries a message starting with {!jail_error_code} when [cwd]
    escapes the jail OR cannot be resolved (nonexistent path, realpath
    failure). *)
val check_cwd_jail : root:string -> cwd:string -> (unit, string) result

val check_request_root_jail
  :  config_root:string
  -> request_root:string
  -> (unit, string) result
(** Whether the jail a request asked for is inside the widest one this host
    allows.

    One host runs endpoints for several Keepers and each has its own root, so
    the shim cannot read the jail from its own config -- doing that makes
    every root but one read as an escape. The request names the jail and this
    keeps it from naming one the host never granted. *)

(** {1 Shim config file}

    The shim learns its jail root from a local file — first
    [$MASC_EXEC_SHIM_CONFIG] when set (used by tests and fixtures), else
    [/etc/masc-exec-shim.conf].  Format: one [key=value] per line, ['#']
    comments and blank lines ignored, keys and values trimmed.  Known
    keys:

    - [remote_root] (required) — absolute path of the playground jail
      root;
    - [env_allowlist] (optional) — comma-separated request-env names the
      shim will overlay (server-side copy of the endpoint allowlist);
      absent means no request env is accepted.

    [path] is optional: a [:]-separated list of absolute directories that
    replaces the payload [PATH] outright. It exists for endpoints whose tools
    live outside the fixed default -- an Apple [container] guest keeps [dune]
    under [/home/opam/.opam/5.5/bin] -- and it is the endpoint operator's
    statement (the file is endpoint-resident), never the wire's. An empty or
    relative entry is rejected.

    Unknown keys, duplicate keys, a missing/relative/empty [remote_root],
    a malformed [path], or an unreadable file are all rejected with
    [remote_ssh_shim_config_error] and the shim refuses to execute. *)

type config =
  { remote_root : string
  ; env_allowlist : string list
  ; payload_path : string list  (** [path=] entries, or {!default_payload_path}. *)
  }

val jail_for_request
  :  config:config
  -> request:Exec_ssh_protocol.request
  -> (unit, string) result
(** The jail one request runs in: its own root must sit inside the host's, and
    its cwd inside its own.

    Exposed so the composition is testable, not only the two halves. Those
    halves passed their tests while the dispatcher still judged every cwd
    against the host's single root, which is what made a second endpoint's own
    directory read as an escape. *)

val parse_config : string -> (config, string) result
val load_config : unit -> (config, string) result

(** {1 Nonblocking drain helper} *)

type drain_result =
  | Drain_bytes of int  (** drained this many bytes; more may follow *)
  | Drain_eof  (** peer closed the pipe *)
  | Drain_again  (** nothing available right now (EAGAIN) *)

val drain_fd : Unix.file_descr -> Buffer.t -> drain_result
(** [drain_fd fd buf] reads [fd] (which MUST be [O_NONBLOCK]) until
    [EAGAIN] or EOF, appending to [buf].  The supervision loop keeps all
    child pipes nonblocking so draining never stalls the timeout/EOF
    watchdogs. *)

(** {1 Entry points} *)

val probe : Exec_ssh_protocol.probe
(** The shim identity.  Its semantic-version major is derived from
    {!Exec_ssh_protocol.protocol_version}, which is the compatibility value
    checked by the SSH runner. *)

val run : unit -> unit
(** Reads one request frame from stdin, executes it under supervision,
    appends the result trailer to stderr.  Exits [0] when the payload was
    supervised to completion (outcome in the trailer), [1] on any
    shim-level failure (trailer with [shim_error] set).

    After the payload is reaped, its output pipes are drained until EOF,
    bounded by a 1s grace so an escaped daemon (double-fork + [setsid]
    defeats process-group kills by design) cannot hang the shim.

    Shim→runner stdout/stderr forwarding writes are BLOCKING: a
    back-pressured ssh channel stalls the supervision loop (deadline,
    grace and EOF detection freeze) until the channel tears down — over
    ssh that is [ServerAliveInterval]×[ServerAliveCountMax] — after which
    the write fails with EPIPE (SIGPIPE is ignored, see {!main}) and the
    On_eof kill policy unsticks the loop.

    Framing limits: the 8-byte big-endian length prefix is capped at
    256 MiB; a larger declared frame or a truncated frame is a
    [remote_ssh_transport_error]. *)

val main : unit -> unit
(** [masc-exec-shim --probe] prints {!probe} via
    {!Exec_ssh_protocol.render_probe} and exits [0]; with no arguments
    runs {!run}; anything else prints usage and exits [2]. *)
