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
    defaults [/tmp], ["masc"], [/tmp]), then the endpoint's declared
    environment ([env_file=], {!endpoint_env}), then the endpoint-allowlisted
    request entries and the runner-owned [GH_CONFIG_DIR],
    [GIT_TERMINAL_PROMPT] and Keeper commit-name
    ({!Exec_ssh_protocol.keeper_git_author_env_names}) entries.  A reserved-name denylist is NEVER accepted
    from the wire — the denylist beats both allowlists. *)

val default_base_path : string
(** [= "/usr/local/bin:/usr/bin:/bin"].  The payload's [PATH] unless the
    endpoint's config names one ([path=], see {!config}); the wire can never
    influence it. *)

val default_payload_path : string list
(** {!default_base_path} split on [:]. *)

val is_executable_file : string -> bool
(** [true] when [path] is a regular file this process may execute. *)

val resolve_program :
  payload_path:string list ->
  is_executable:(string -> bool) ->
  string ->
  string option
(** The file the shim executes for a request's program name. A name
    containing ['/'] is returned as given. Otherwise the first directory of
    [payload_path] (the endpoint's [path=], or {!default_payload_path}) holding
    an entry for which [is_executable] holds names it; [None] when none does.

    The shim does not leave this to [Unix.execvpe]: that searches the shim
    process's own [PATH], not the [PATH] in the environment it is given, so a
    tool that lives only in a [path=] directory was never found. *)

val denylisted_env_name : string -> bool
(** [true] for names never accepted from the wire: [PATH], [HOME],
    [LD_PRELOAD], [LD_LIBRARY_PATH], [BASH_ENV], [ENV], and every name
    with the [DYLD_] prefix.  Matching is case-sensitive; [PATH] from the
    wire is dropped even when it appears in the endpoint allowlist. *)

type endpoint_env = private (string * string) list
(** The environment an endpoint's operator declares for every payload, read
    from the file the shim config's [env_file=] names: what a person logged in
    on that host runs with and the minimal base env does not carry (a venv's
    [VIRTUAL_ENV], a CUDA [LD_LIBRARY_PATH]).  It is endpoint-resident like
    [path=], so {!denylisted_env_name} does not apply to it: an operator may
    declare [LD_LIBRARY_PATH].  [PATH] is refused — [path=] is also the list
    {!resolve_program} searches, and one source keeps the payload's [PATH]
    and that search the same.  Built only by {!parse_env_file}.

    In a boxed run ([observe], [guest_local]) [HOME] and [TMPDIR] are the
    run's scratch directory ({!scratch_env}) whatever the file declares.
    Other directories the file names lie outside the box: under [observe]
    a payload's writes there are refused. *)

val no_endpoint_env : endpoint_env
(** The endpoint declares nothing: no [env_file=]. *)

val parse_env_file : path:string -> string -> (endpoint_env, string) result
(** docker's [--env-file] grammar without its host-lookup form.  One
    [NAME=VALUE] per line; [NAME] is [[A-Za-z_][A-Za-z0-9_]*] starting at the
    first column; [VALUE] is the rest of the line byte for byte (untrimmed,
    may contain [=]).  One ['\r'] before the line end is dropped, as docker's
    line reader drops it, so a file with CRLF endings declares the same
    values.  Blank lines and lines whose first non-blank character is ['#']
    are skipped.  A line without [=] (docker's "take it from the reader's
    environment", which here would be an sshd session's), an invalid name,
    [PATH], a GitHub token name ({!Exec_ssh_protocol.github_token_env_names}:
    one token would make every keeper on the endpoint one GitHub identity), a
    name the runner sets for each request ([GH_CONFIG_DIR],
    [GIT_TERMINAL_PROMPT], [GIT_AUTHOR_NAME], [GIT_COMMITTER_NAME]), a value holding a NUL byte, or a name declared
    twice is rejected with [remote_ssh_shim_config_error].

    [path] is the file the content was read from and appears only in the
    error.  The error prints that path, the line number, and only the fixed
    names it refuses ([PATH], the GitHub token names, [GH_CONFIG_DIR],
    [GIT_TERMINAL_PROMPT], [GIT_AUTHOR_NAME], [GIT_COMMITTER_NAME]) — never other text from the line, since a
    malformed line may be a secret value. *)

val synthesize_env :
  path:string ->
  endpoint_env:endpoint_env ->
  base_env:(string * string) list ->
  allowlist:string list ->
  request_env:(string * string) list ->
  (string * string) list
(** [synthesize_env ~endpoint_env ~base_env ~allowlist ~request_env] is the
    payload's full environment: the minimal base env (see above; [base_env] is
    the shim's own process environment — the function itself is pure and
    performs no process-state lookups; [path] is the payload [PATH], the
    endpoint config's [payload_path] joined on [:]), with [endpoint_env]
    replacing or adding its names,
    then each non-denylisted request entry overlaid
    when its name is in [allowlist] or is one of the runner-owned
    [GH_CONFIG_DIR], [GIT_TERMINAL_PROMPT], [GIT_AUTHOR_NAME] and
    [GIT_COMMITTER_NAME] names.  A request entry whose
    name collides with a base or endpoint name replaces that value.  Duplicate names in
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
  ?observed_syscalls:int list ->
  v:Exec_ssh_protocol.major -> timed_out:bool -> Unix.process_status -> Exec_ssh_protocol.trailer
(** Maps a reaped child status to the result trailer: [WEXITED n] →
    [exit = Some n], [WSIGNALED n] → [signal = Some] of the {b host OS}
    signal number (via {!host_signal_number} — the wire must carry 9 or
    15, never OCaml's abstract codes).  ([WSTOPPED] cannot occur: the
    shim never passes [WUNTRACED] to [waitpid]; it is mapped like
    [WSIGNALED] defensively.)  The result always satisfies the codec's
    trailer invariants (exactly one of [exit]/[signal] set,
    [shim_error = None]).  [observed_syscalls] defaults to [[]]; a
    caller running Observe mode passes the supervisor drain's
    accumulated syscall numbers through to carry them in the same
    typed result rather than a side-channel text line. *)

(** {1 Server-side path jail}

    Defense in depth: the runner-side gate is layer 1, the shim
    re-applies the jail without trusting the wire.  The jail root comes
    from a local config file, never from the request. *)

val jail_error_code : string
(** [= "remote_ssh_path_jail_violation"]. *)

val config_error_code : string
(** [= "remote_ssh_shim_config_error"]. *)

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

    [env_file] is optional: the absolute path of a file declaring the
    payload's environment ({!endpoint_env}, grammar in {!parse_env_file}).
    The shim reads it for every request and refuses the request with
    [remote_ssh_shim_config_error] when it is not a regular file, cannot be
    read, is malformed, or fails {!refuse_endpoint_file}.

    Unknown keys, duplicate keys, a missing/relative/empty [remote_root],
    a malformed [path], a relative or empty [env_file] or [scratch_root], or
    a config path that is not a regular file, fails {!refuse_endpoint_file}
    or cannot be read are all rejected with [remote_ssh_shim_config_error]
    and the shim refuses to execute.  Only a regular file is read, and that
    and its owner and mode are decided before reading, so a FIFO at the path
    is refused rather than waited on.  An error names a key or a line
    number, never text from the file. *)

type config =
  { remote_root : string
  ; env_allowlist : string list
  ; payload_path : string list  (** [path=] entries, or {!default_payload_path}. *)
  ; env_file : string option  (** [env_file=], absolute; [None] when absent. *)
  ; scratch_root : string
    (** [scratch_root=] (absolute): where a boxed run gets its one writable
        directory, which is also the payload's HOME and TMPDIR and is removed
        after the run. Absent means {!Exec_ssh_protocol.default_scratch_root},
        where the microvm boot mounts the guest's in-memory filesystem. *)
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

type endpoint_file_writers =
  | Its_group
  | Every_user
  | Its_group_and_every_user

type endpoint_file_refusal =
  | Owned_by of int  (** the file's owner uid: neither root nor the shim's *)
  | Writable_by of endpoint_file_writers  (** who besides the owner may write it *)

val refuse_endpoint_file :
  euid:int -> owner:int -> perm:int -> endpoint_file_refusal option
(** Why the config file or an env file with owner uid [owner] and permission
    bits [perm] is refused by a shim whose effective uid is [euid]; [None]
    when it may be read.  Whoever writes the config names the payload [PATH]
    and the env file, and whoever writes the env file sets every payload's
    environment, so the rule for both is sshd's StrictModes: the owner is
    root or [euid], and neither its group nor every user may write it.  An
    owner outside those two is reported first.  A file owned by the shim's
    own account passes, but that account runs the payloads and they can
    rewrite it: keep both files root-owned [0644]. *)

val read_config_file : string -> (config, string) result
(** The config at a path through {!parse_config}.
    [remote_ssh_shim_config_error] when the path is not a regular file, when
    {!refuse_endpoint_file} refuses its owner or mode (both decided before the
    file is read), or when it cannot be read.  The shim reads
    [$MASC_EXEC_SHIM_CONFIG] or [/etc/masc-exec-shim.conf] through it. *)

val read_env_file : string option -> (endpoint_env, string) result
(** {!no_endpoint_env} for [None]; otherwise the named file through
    {!parse_env_file}.  [remote_ssh_shim_config_error] when the path is not a
    regular file, when {!refuse_endpoint_file} refuses its owner or mode (both
    decided before the file is read), or when it cannot be read.  The error
    names the path, and the owner uid or the mode, as a number. *)

val payload_env :
  config:config ->
  base_env:(string * string) list ->
  request_env:(string * string) list ->
  ((string * string) list, string) result
(** The environment one request's payload runs with: [config]'s [env_file]
    read and layered by {!synthesize_env} under [config]'s [path=] and
    [env_allowlist].  Exposed so the composition the dispatcher runs is
    testable, like {!jail_for_request}. *)

(** {1 The box (RFC-0422)} *)

val observe_supported : unit -> bool
(** Whether this kernel lets the shim box a payload: Landlock ABI >= 1 and
    seccomp filtering, read through the syscalls themselves. Always [false]
    off Linux. *)

val user_notif_supported : unit -> bool
(** Whether this kernel accepts [SECCOMP_FILTER_FLAG_NEW_LISTENER] (Linux
    >= 5.0). A capability probe only (task-1568, follow-up to PR #36032
    review 5192723206): the observation path a refused-observe shortcut
    would need — recording the payload's actual attempt after the "A"
    acknowledgement, rather than only that the box applied — requires a
    listener fd carried from the child to the parent (a new SCM_RIGHTS
    stub; a plain pipe cannot carry a file descriptor) and a supervisor
    loop that reads, decodes and responds to notifications. Neither exists
    yet: {!probe} reports this as
    {!Exec_ssh_protocol.user_notif_capability} so the value is read on the
    wire, but nothing decodes a notify-fd attempt from it and
    {!Keeper_gate.decide_after_observation} does not consult it. It probes
    by forking a throwaway child that tries
    to install an allow-all listener filter and exits without running a
    payload; the calling thread's own seccomp state is never touched
    (installing a filter can only add restrictions, so the flag cannot be
    probed in-process without a side effect that outlives the probe).
    Always [false] off Linux. *)

type execution_plan =
  | Run_effect  (** unrestricted, as before v3 *)
  | Run_boxed of
      { deny_fs : bool  (** Landlock: writes only under scratch or to verified /dev/null *)
      ; deny_net : bool  (** seccomp: [socket(2)] answers EPERM *)
      }
  | Refuse_observe_unsupported

val plan_for_mode : supported:bool -> Exec_ssh_protocol.mode -> execution_plan
(** [Effect] runs unboxed; [Observe] denies persistent filesystem writes and sockets,
    allowing its scratch and the verified /dev/null discard device;
    [Guest_local] denies sockets. Either box on an unsupported host is a
    refusal. Pure, so the decision is pinned by a test on every host. *)

val child_boundary_of_ack : string -> Exec_ssh_protocol.execution_boundary
(** Decode the fixed child-owned status-pipe protocol: setup acknowledgement,
    exec failure after setup, setup failure, or a setup refusal attributed
    by the child to one of its own rules ("N" socket filter, "W" Landlock
    write ruleset). Empty/invalid/incomplete bytes mean unavailable
    evidence, never applied restrictions. *)

exception Sandbox_refused_socket
(** The child's seccomp socket filter could not be installed: the box did
    NOT apply. Raised in the forked child before exec, caught by {!spawn}
    and reported as the "N" acknowledgement. *)

exception Sandbox_refused_write
(** The child's Landlock write ruleset could not be installed: the box did
    NOT apply. Reported as the "W" acknowledgement. *)

val refusal_of_rule_bytes : bytes -> exn
(** Map the C stub's fixed-size rule-name buffer to the refusal exception
    that names it, trimming trailing NUL padding by content. Pure, so the
    emission mapping is pinned by a test without a real seccomp/Landlock
    refusal; an unrecognized rule raises [Failure]. *)

val scratch_env : scratch:string -> (string * string) list -> (string * string) list
(** The payload environment with HOME and TMPDIR pointing at the scratch. *)

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

val probe : unit -> Exec_ssh_protocol.probe
(** The shim identity.  Its semantic-version major is derived from
    {!Exec_ssh_protocol.protocol_version}, which is the compatibility value
    checked by the SSH runner. [capabilities] carries
    {!Exec_ssh_protocol.observe_capability} exactly when {!observe_supported}
    is true on this host. *)

val main : unit -> unit
(** [masc-exec-shim --probe] prints {!probe} via
    {!Exec_ssh_protocol.render_probe} and exits [0]; with no arguments
    runs [run]; anything else prints usage and exits [2]. *)
