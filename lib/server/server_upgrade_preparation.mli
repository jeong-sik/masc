(** Preparation to stop the server of a single user that the kernel names as
    lease owner and port announcer. Nothing here starts a process or forces
    one down. *)
type t
type error = Invalid_health  (** The port gave no compact [/health] version. *)
  | Admin_required | Owner_unavailable
  | Incumbent_changed
      (** The kernel no longer names the witnessed process as lease owner and
          port announcer, or it answers another version. *)
  | Already_requested | Closed | Port_unavailable

(** {1 Who holds a workspace, as the kernel says} *)

type single_user_server
(** The server of a single user that one kernel read named both as the lease
    owner of a BasePath and as the holder of the single-user announcement
    byte of a port ({!Server_startup_takeover.single_user_server_port_holder}).
    Only {!owner} and {!owner_without_making} make one. The sends of a
    credential in this module, in [Masc_cli_runtime_config_remote] and in
    [Masc_cli_model_resume] take one and call {!confirm} right before the
    send. [masc setup] calls {!confirm} in the caller, before the sign-in and
    before the Keeper boot. Other senders of the bearer, such as
    [masc keeper up], do not make this read. *)

val single_user_server_pid : single_user_server -> int
val single_user_server_port : single_user_server -> int
val single_user_server_base_path : single_user_server -> string
(** The BasePath the lease was read for, as the caller gave it. *)

type owner =
  | Single_user_server_here of single_user_server
  | Single_user_server_elsewhere of { pid : int; port : int }
      (** The owner announces [port] on the single-user file, not the port
          asked about. *)
  | Account_server_here of { pid : int }
  | Account_server_elsewhere of { pid : int; port : int }
  | Owner_unannounced of { pid : int }
      (** A process holds the lease, and the kernel shows no announcement of
          it on either file. The kernel does not say which of these it is: a
          server still booting before its bind, a server that shuts down (it
          withdraws the announcement when its listener closes, before it
          lets go of the lease), a server that listens on an address
          [127.0.0.1] does not reach and so never announces, a server older
          than the announcement, or an owner whose whole-file announcement
          the lock of another process hid. *)
  | Unowned  (** Nothing holds the lease. *)

val owner :
  run_dir:string -> base_path:string -> port:int ->
  (owner, Server_startup_takeover.owner_capture_error) result
(** One capture of the lease owner
    ({!Server_startup_takeover.capture_existing_owner}). The owner pid is
    compared with the holder of the single-user byte of [port], then with the
    holder of the account-server byte of [port]. For the [_elsewhere]
    answers the whole-file reads
    ({!Server_startup_takeover.single_user_server_announcement}, then
    {!Server_startup_takeover.account_server_announcement}) are consulted
    only to name the other port; a lock of another process can hide the
    owner from them, and the answer is then [Owner_unannounced]. Nothing is
    signalled. Like {!replacement_readiness}, it makes the private lease
    directory and an empty lease file when they are missing. An [Error] when
    the lease or an announcement cannot be read.

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

val confirm : single_user_server -> (unit, departure) result
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
    lists the four causes the kernel does not tell apart, each with what to
    do. *)

val departure_sentence : single_user_server -> departure -> string
(** What a command tells the operator when {!confirm} refused the server it
    had been given. *)

val compact_health_version : string -> string option
(** The [version] of a compact [/health] body: one object with unique keys
    and a non-empty string ["version"]. This field stays public without
    credentials. Nothing else in the body is read: which process answers is
    what the kernel said before the port was asked. [None] for any other
    body. *)

(** {1 The stop of the server of a single user} *)

val authorize_initial :
  clock:[> float Eio.Time.clock_ty] Eio.Resource.t -> single_user_server ->
  expected_version:string -> login:(unit -> bool) -> (unit, error) result
(** In order: {!confirm} ([Incumbent_changed] when the kernel names another
    answer, [Owner_unavailable] when it cannot be read); a compact
    [GET /health] on the announced port within
    {!Masc_http_client.default_request_timeout_sec} ([Invalid_health] when no
    version is read); a version other than [expected_version] gives
    [Incumbent_changed]; then [login ()] ([Admin_required] on [false]).
    [login] mints the admin credential, so it never runs before the kernel
    check. *)

val prepare :
  sw:Eio.Switch.t -> clock:[> float Eio.Time.clock_ty] Eio.Resource.t -> headers:(string * string) list ->
  single_user_server -> (t, error) result
(** In order: capture the lease owner handle ([Owner_unavailable] when
    nothing holds the lease or the owner cannot be read) and require its pid
    to be the pid of the server ([Incumbent_changed] otherwise, and the
    handle is released); {!confirm} ([Incumbent_changed] when the kernel
    names another answer, [Owner_unavailable] when it cannot be read); then
    the first send of [headers],
    [GET /api/v1/runtime/config/raw] on the announced port within the
    default timeout ([Admin_required] unless it answers 200). The handle is
    released on a refusal, and on the release of [sw]. *)

val request_termination : t -> (unit, error) result
(** Call only after the user selects replacement. In order: {!confirm}; the
    second send of the headers; then the identity-bound SIGTERM through the
    captured handle, which refuses a process that is no longer the one
    captured. Success is a request, not proof of drain. Caller waits for
    lease/port release and starts the replacement with the same workspace
    and existing authentication. *)

val close : t -> unit
val suggest_loopback_port : unit -> (int, error) result
(** OS-selected candidate, not a reserved port. Recheck conflicts at startup. *)

module For_testing : sig
  val authorize_initial :
    confirm:(unit -> (unit, error) result) -> version:(unit -> string option) ->
    expected_version:string -> login:(unit -> bool) -> (unit, error) result
  (** The order of {!authorize_initial}, over the kernel check and the
      version read it is given. *)

  val prepare : sw:Eio.Switch.t ->
    capture:(unit -> (((unit -> (unit, error) result) * (unit -> unit)), error) result) ->
    confirm:(unit -> (unit, error) result) ->
    authorize:(unit -> bool) ->
    (t, error) result
  (** The order of {!prepare}, over the capture, the kernel check and the
      authorized send it is given. *)
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
