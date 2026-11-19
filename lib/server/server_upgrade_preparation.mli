(** Preparation to stop the server of a single user that the kernel names as
    lease owner and port announcer. Nothing here starts a process or forces
    one down. *)
type t

(** {1 Who holds a workspace, as the kernel says} *)

type single_user_listener
(** Proof that one kernel read named the process that holds the lease of a
    BasePath as the holder of the single-user announcement byte of a port
    ({!Server_startup_takeover.single_user_server_port_holder}). Only
    {!owner} makes one ({!owner_without_making} hands its answer on;
    {!For_testing.owner} answers with the bare pid), so a function that takes
    one cannot be reached with a port that was merely asked about or that
    merely answered over HTTP. It is what was true at the read: every send of
    the bearer of the operator that takes one calls {!confirm} right before
    it, in this module ({!authorize_initial}, {!prepare},
    {!request_termination}), in [Masc_cli_runtime_config_remote] and in
    [Masc_cli_model_resume]. [masc setup] calls {!confirm} in the caller,
    before the sign-in and before the Keeper boot. Other senders of the
    bearer do not make this read: [masc keeper up], [masc keeper-create] and
    the requests of the TUI. *)

val listener_pid : single_user_listener -> int
val listener_port : single_user_listener -> int
val listener_base_path : single_user_listener -> string
(** The BasePath the lease was read for, as the caller gave it. *)

type 'here kernel_owner =
  | Single_user_server_here of 'here
      (** The owner holds the single-user byte of the port asked about. In an
          {!owner} the payload is the {!single_user_listener}. *)
  | Single_user_server_elsewhere of { pid : int; port : int }
      (** The owner announces [port] on the single-user file, not the port
          asked about. *)
  | Account_server_here of { pid : int }
  | Account_server_elsewhere of { pid : int; port : int }
  | Owner_unannounced of { pid : int }
      (** A process holds the lease, and the kernel shows no announcement of
          it on either file. The kernel does not say which of these five it
          is: a server still booting before its bind, a server that shuts
          down (it withdraws the announcement when its listener closes,
          before it lets go of the lease), an owner that announces another
          port, hidden from the whole-file read by the lock of another
          process, a server that listens on an address [127.0.0.1] does not
          reach and so never announces, or a server older than the
          announcement. *)
  | Unowned  (** Nothing holds the lease. *)

type owner = single_user_listener kernel_owner

val owner :
  run_dir:string -> base_path:string -> port:int ->
  (owner, Server_startup_takeover.owner_capture_error) result
(** One read of the pid of the lease owner
    ({!Server_startup_takeover.existing_owner_pid}), which takes no handle on
    the process, so a host without a pidfd answers too. The owner pid is
    compared with the holder of the single-user byte of [port], then with the
    holder of the account-server byte of [port]. A lock that another process
    holds on either byte names nothing. For the [_elsewhere] answers the
    whole-file reads
    ({!Server_startup_takeover.single_user_server_announcement}, then
    {!Server_startup_takeover.account_server_announcement}) are consulted
    only to name the other port; a lock of another process can hide the
    owner from them, and the answer is then [Owner_unannounced]. Nothing is
    signalled. Like {!replacement_readiness}, it makes the private lease
    directory and an empty lease file when they are missing; a command that
    must make nothing asks {!owner_without_making}. An [Error] when the lease
    or an announcement cannot be read.

    The lease is read before the announcements. Before [Owner_unannounced]
    is answered the lease is read once more: [Unowned] when the owner left
    meanwhile, and an [Owner_identity_unavailable Owner_changed] error when
    another process took the lease, so the pid named still holds it. *)

val owner_without_making :
  Host_config.base_path_lease_root -> base_path:string -> port:int ->
  (owner, Server_startup_takeover.owner_capture_error) result
(** {!Server_startup_takeover.lease_file_present} first: [Ok Unowned] when
    the lease file was never made, and then nothing is made, not the run
    directory either. Otherwise {!Server_startup_takeover.lease_run_dir} and
    {!owner}, which finds nothing left to make. A root or a path to the lease
    file that cannot be read is an [Owner_lease_rejected]. *)

type departure =
  | Announcement_withdrawn of { pid : int }
      (** The same process still holds the lease and announces no port any
          more: the server closed its listener, as it does when it shuts
          down. *)
  | Owner_now of owner  (** The kernel now names something else. *)
  | Owner_unreadable of Server_startup_takeover.owner_capture_error

val confirm : single_user_listener -> (unit, departure) result
(** {!owner} again for the same run directory, BasePath and port. [Ok ()]
    only when the answer is [Single_user_server_here] with the same pid. *)

val lease_directory : Host_config.base_path_lease_root -> base_path:string -> string
(** The directory the lease of [base_path] is looked for in, as a name to
    show: [<base_path>/.masc-owner], or the directory
    [MASC_BASE_PATH_LEASE_DIR] names. Nothing is read or made. A server
    started with another lease root holds its lease elsewhere, and no read
    here sees it. *)

val owner_sentence : lease_dir:string -> base_path:string -> port:int -> owner -> string
(** What a command tells the operator about each answer of {!owner}, for
    [base_path] asked about on [port]. Each command appends what it did not
    do. The sentence for [Unowned] names [lease_dir], the directory the lease
    was read in ({!lease_directory}). The sentence for [Owner_unannounced]
    lists the five causes the kernel does not tell apart, the ones the type
    names, each with what to do. *)

val departure_sentence : single_user_listener -> departure -> string
(** What a command tells the operator when {!confirm} refused the server it
    had been given. *)

val compact_health_version : string -> string option
(** The [version] of a compact [/health] body: one object with unique keys
    and a non-empty string ["version"]. This field stays public without
    credentials. Nothing else in the body is read: which process answers is
    what the kernel said before the port was asked. [None] for any other
    body. *)

(** {1 The stop of the server of a single user} *)

type error =
  | Invalid_health  (** The port gave no compact [/health] version. *)
  | Sign_in_failed
      (** The local sign-in of this command failed or left no credential it
          could read. Nothing was sent to the running server. *)
  | Admin_required
      (** The running server answered 401 or 403 to the operator credential
          that this command had just checked or written for the workspace:
          this MASC accepts the credential and the server does not. *)
  | Server_starting
      (** [/health/ready] of the running server says it is not ready yet. It
          was not asked about the credential. Signing in does not change
          this; the server becoming ready does. *)
  | Admin_check_unanswered
      (** The running server gave no verdict on the credential: another
          status than 200, 401 or 403, or no answer. *)
  | Owner_unavailable
      (** The lease owner could not be captured for the stop: the lease was
          refused, or the system gives no handle on the process. *)
  | Incumbent_changed
      (** The server answers another version, the lease owner is not the
          account server of the port, or the kernel named [listener] again
          after the capture of the stop found another process. *)
  | Not_confirmed of { listener : single_user_listener; departure : departure }
      (** {!confirm} refused [listener] right before a step of the stop, or
          the capture of the stop found nobody or another process where the
          kernel had named [listener]. [departure] says what the kernel names
          now: the pid that withdrew its announcement, another owner, or the
          reason the owner could not be read. {!departure_sentence} words
          it. *)
  | Already_requested | Closed | Port_unavailable

val authorize_initial :
  clock:[> float Eio.Time.clock_ty] Eio.Resource.t -> single_user_listener ->
  expected_version:string -> login:(unit -> bool) -> (unit, error) result
(** In order: {!confirm} ([Not_confirmed] with the departure when it
    refuses); a compact [GET /health] on the announced port within
    {!Masc_http_client.default_request_timeout_sec} ([Invalid_health] when no
    version is read); a version other than [expected_version] gives
    [Incumbent_changed]; then [login ()] ([Sign_in_failed] on [false]).
    [login] mints the admin credential, so it never runs before the kernel
    check. *)

val prepare :
  sw:Eio.Switch.t -> clock:[> float Eio.Time.clock_ty] Eio.Resource.t ->
  listener:single_user_listener -> token:string -> agent:string -> (t, error) result
(** Prepares the stop of the server of a single user. The bearer [token] of
    the operator is put in a request here and in {!request_termination}, and
    the only port it can go to is the one inside [listener]. In order:
    capture the lease owner handle and require its pid to be the pid of
    [listener] ([Not_confirmed] with what the kernel names now when nobody
    or another process holds the lease, and the handle is released;
    [Owner_unavailable] when the lease is refused or the system gives no
    handle); [GET /health/ready] without credentials ([Server_starting] when
    it says the server is not ready); {!confirm} ([Not_confirmed] with the
    departure when it refuses), with no request between it and the bearer;
    then the first request with the bearer,
    [GET /api/v1/runtime/config/raw] on the announced port ([Admin_required]
    on 401 or 403, [Admin_check_unanswered] on any other status than 200 or
    no answer). The handle is released on a refusal, and on the release of
    [sw]. *)

val request_termination : t -> (unit, error) result
(** Call only after the user selects replacement. In order: the readiness,
    {!confirm} and the second request with the bearer, as in {!prepare};
    then the identity-bound SIGTERM through the captured handle, which
    refuses a process that is no longer the one captured. Success is a
    request, not proof of drain. Caller waits for lease/port release and
    starts the replacement with the same workspace and existing
    authentication. *)

val close : t -> unit
val suggest_loopback_port : unit -> (int, error) result
(** OS-selected candidate, not a reserved port. Recheck conflicts at startup. *)

type http_answer = (int * string, string) result
(** One loopback GET as {!Masc_http_client.get_sync} hands it over: the status
    and the body, or why no answer came. *)

module For_testing : sig
  val owner :
    lease_owner:(unit -> (int, Server_startup_takeover.owner_capture_error) result) ->
    single_holder:(unit -> (int option, Server_startup_takeover.base_path_lock_rejection) result) ->
    account_holder:(unit -> (int option, Server_startup_takeover.base_path_lock_rejection) result) ->
    single_seen:
      (unit ->
       ( Server_startup_takeover.single_user_server_announcement option
       , Server_startup_takeover.base_path_lock_rejection ) result) ->
    account_seen:
      (unit ->
       ( Server_startup_takeover.account_server_announcement option
       , Server_startup_takeover.base_path_lock_rejection ) result) ->
    port:int ->
    (int kernel_owner, Server_startup_takeover.owner_capture_error) result
  (** The order of {!owner}, over the reads it is given. [lease_owner]
      answers the pid of the lease owner and is asked a second time only
      before [Owner_unannounced] is answered. [Single_user_server_here]
      carries that pid and no {!single_user_listener}, so no send of a
      credential can be reached from these reads. *)

  val authorize_initial :
    confirm:(unit -> (unit, error) result) -> version:(unit -> string option) ->
    expected_version:string -> login:(unit -> bool) -> (unit, error) result
  (** The order of {!authorize_initial}, over the kernel check and the
      version read it is given. *)

  val prepare : sw:Eio.Switch.t ->
    capture:(unit -> (((unit -> (unit, error) result) * (unit -> unit)), error) result) ->
    confirm:(unit -> (unit, error) result) ->
    readiness:(unit -> http_answer) -> access:(unit -> http_answer) ->
    (t, error) result
  (** The order of {!prepare}, over the capture, the kernel check and the
      answers the caller supplies: [readiness] is the answer of
      [/health/ready], [access] the answer of the admin route to the bearer.
      [confirm] is asked after [readiness] and right before [access]. Neither
      is asked when [readiness] says the server is still starting, and
      [access] is not asked when [confirm] refuses. *)
end

type replacement_readiness = Owner_draining | Port_busy | Replacement_can_start
type termination_outcome =
  | Not_requested of error
  | Requested of (replacement_readiness, error) result
(** A confirmed identity-bound termination request remains [Requested] even if
    observing lease/port release fails. None of these states proves process exit. *)

val request_termination_and_observe :
  t -> observe:(unit -> (replacement_readiness, error) result) -> termination_outcome
(** Requests once through {!request_termination}, then observes readiness.
    Pre-request refusal never invokes [observe]. Observation errors, including
    Unix/file failures, preserve the confirmed request; cancellation propagates. *)

val replacement_readiness :
  run_dir:string -> base_path:string -> port:int -> (replacement_readiness, error) result
(** Observe kernel lease release and loopback bind availability after requesting
    graceful termination. Never signals or starts anything; errors are not exit
    proof. Availability is advisory, so replacement startup still owns conflicts. *)

val stop_account_server : run_dir:string -> base_path:string -> port:int -> (unit, error) result
(** Asks the account server of a multi-account installation to stop: the
    identity-bound SIGTERM of {!request_termination}, sent to the kernel owner
    of the lease of [base_path] when that same process holds the announcement
    lock of [port] ({!Server_startup_takeover.account_server_port_holder}).
    [Incumbent_changed] when the owner does not announce [port], or changed
    between the reads. [Owner_unavailable] when nothing holds the lease, or
    the owner or the announcement cannot be read. Success is a request, not
    proof of drain.

    {b Authority.} An account server has no admin credential that a command
    line could present: its accounts are persons who sign in through a
    browser. This stop rests on the authority of the host, as [masc auth]
    does: the effective UID that owns the private lease directory, which the
    kernel checks when the lease is opened and when the signal is sent. Call
    it only after the operator chose the replacement. *)

(** What one read of [/health/ready] on the port of a replacement said. *)
type readiness_answer =
  | Answered_ready  (** 200. Nothing in the body is read. *)
  | Not_ready  (** Another status, or no answer. *)

(** What that answer says of the replacement a command started. *)
type replacement_sighting =
  | Replacement_serves
      (** The port answered ready, and the replacement holds its
          announcement byte. *)
  | Another_process_announces of { pid : int }
      (** [pid], not the replacement, holds the announcement byte of the
          port: the predecessor still drains. *)
  | Nobody_announces
      (** No process holds the announcement byte of the port. *)
  | Announcement_unreadable of Server_startup_takeover.base_path_lock_rejection
  | No_ready_answer

val replacement_sighting :
  child_pid:int ->
  readiness_answer ->
  port_holder:(unit -> (int option, Server_startup_takeover.base_path_lock_rejection) result) ->
  replacement_sighting
(** Whether the replacement [child_pid] is the server that answered ready.
    It answers on the port its predecessor drains on, so a 200 counts only
    once [child_pid] holds the announcement byte of the port: [port_holder]
    names that holder and is asked once. No pid in the answer is read.
    Without a ready answer nothing is asked: a process that announces and
    does not answer is not ready. *)
