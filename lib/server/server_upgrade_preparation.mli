(** Explicit upgrade preparation for an existing owner, including older servers
    without the model-setup resume endpoint. No process starts or forced kills. *)
type t
type error =
  | Invalid_health
  | Different_workspace
  | Admin_required
      (** The local sign-in failed or left no credential, or the running
          server read the credential and refused it (401 or 403). *)
  | Server_starting
      (** [/health/ready] of the running server says it is not ready yet. It
          was not asked about the credential. Signing in does not change
          this; the server becoming ready does. *)
  | Admin_check_unanswered
      (** The running server gave no verdict on the credential: another
          status than 200, 401 or 403, or no answer. *)
  | Owner_unavailable
  | Incumbent_changed | Already_requested | Closed | Port_unavailable
type incumbent = { base_path : string; version : string }
val decode_health : string -> (incumbent, error) result
(** Strict unique-field health identity decoding, without authentication or writes. *)

val authorize_initial : base_path:string -> expected_version:string -> body:string ->
  login:(unit -> bool) -> (unit, error) result
(** Validates workspace and selected version before invoking the login callback. *)

val prepare :
  sw:Eio.Switch.t -> clock:[> float Eio.Time.clock_ty] Eio.Resource.t -> headers:(string * string) list ->
  run_dir:string -> base_path:string -> port:int -> (t, error) result
val incumbent : t -> incumbent
val request_termination : t -> (unit, error) result
(** Call only after the user selects replacement. Rechecks workspace/version,
    readiness and admin authentication immediately before identity-bound SIGTERM. Success is
    a request, not proof of drain. Caller waits for lease/port release and starts
    the replacement with the same workspace and existing authentication. *)

val close : t -> unit
val suggest_loopback_port : unit -> (int, error) result
(** OS-selected candidate, not a reserved port. Recheck conflicts at startup. *)

type http_answer = (int * string, string) result
(** One loopback GET as {!Masc_http_client.get_sync} hands it over: the status
    and the body, or why no answer came. *)

module For_testing : sig
  val prepare : sw:Eio.Switch.t -> base_path:string -> observe:(unit -> (string, error) result) ->
    readiness:(unit -> http_answer) -> access:(unit -> http_answer) ->
    capture:(unit -> (((unit -> (unit, error) result) * (unit -> unit)), error) result) ->
    (t, error) result
  (** {!prepare} over answers the caller supplies: [readiness] is the answer
      of [/health/ready], [access] the answer of the admin route to the
      bearer. [access] is not asked when [readiness] says the server is
      still starting. *)
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

(** What the kernel says of the account server of a workspace, for a command
    that was asked about one port. *)
type account_server =
  | Account_server_on_port of { pid : int }
      (** The kernel owner of the lease holds the announcement lock of the
          port ({!Server_startup_takeover.account_server_port_holder}). *)
  | Account_server_on_another_port of { pid : int; port : int }
      (** The kernel owner of the lease announces [port], not the one asked
          about. *)
  | Owner_announces_nothing
      (** A process holds the lease and announces nothing the kernel showed:
          the server of a single user, an account server that has not
          announced yet, or one whose announcement the lock of another
          process hid from a read about another port. *)
  | No_owner  (** Nothing holds the lease. *)

val account_server :
  run_dir:string -> base_path:string -> port:int ->
  (account_server, Server_startup_takeover.owner_capture_error) result
(** Reads the kernel owner of the lease of [base_path] and compares it with
    the holder of the announcement lock of [port]. [Account_server_on_port]
    comes from that byte alone. A lock that a process other than the owner
    holds on the announcement file is no account server, whichever byte it
    is on. The other port is read over the whole file
    ({!Server_startup_takeover.account_server_announcement}), which names
    nothing else here, and can be missed behind such a lock; the answer is
    then [Owner_announces_nothing]. It signals nothing, and the pid is a
    number to show: {!stop_account_server} reads the owner again. An [Error]
    when the lease or the announcement cannot be read.

    The read makes the private lease directory and an empty lease file when
    they are missing, as {!replacement_readiness} does. A command that must
    make nothing asks {!holder}. *)

(** Who holds a BasePath, for a command that must make nothing. *)
type holder =
  | Held_by_nobody
      (** No lease file was ever made, or nothing holds the one there. *)
  | Held_without_announcement  (** {!Owner_announces_nothing}. *)
  | Held_by_account_server of { port : int }
      (** The owner announces [port]: the one asked about, or another. *)

val holder :
  Host_config.base_path_lease_root -> base_path:string -> port:int ->
  (holder, Server_startup_takeover.owner_capture_error) result
(** {!account_server} behind {!Server_startup_takeover.lease_file_present}.
    A lease file that was never made was never held: then no owner is read
    and nothing is made, not the lease root either. Once the file is there
    the read of the owner finds nothing left to make. [port] is the port the
    announcement is first looked for on, as in {!account_server}. An [Error]
    when the lease root, the lease or the announcement cannot be read; a root
    or a path to the lease file that cannot be read is an
    [Owner_lease_rejected]. *)

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
  | Ready_named of int
      (** A 200 that carries the pid of the process that answered: the server
          of a single user. *)
  | Ready_unnamed
      (** A 200 that names no process: the probes of an account server. *)
  | Not_ready  (** Another status, or no answer. *)

(** What that answer says of the replacement a command started. *)
type replacement_sighting =
  | Replacement_serves
      (** The ready answer is the replacement's own. *)
  | Another_server_answers of { pid : int }
      (** A ready answer of another process: the predecessor still drains. *)
  | Another_process_announces of { pid : int }
      (** The answer names no process, and [pid], not the replacement, holds
          the announcement lock of the port. *)
  | Nobody_announces
      (** The answer names no process, and no process holds the announcement
          lock of the port. *)
  | Announcement_unreadable of Server_startup_takeover.base_path_lock_rejection
  | No_ready_answer

val replacement_sighting :
  child_pid:int ->
  readiness_answer ->
  port_holder:(unit -> (int option, Server_startup_takeover.base_path_lock_rejection) result) ->
  replacement_sighting
(** Whether the replacement [child_pid] is the server that answered ready.
    It answers on the port its predecessor drains on, so a 200 counts only
    once it is the replacement's own. An answer that names its process is
    the replacement's when that pid is [child_pid]; [port_holder] is not
    asked, so a server of a single user is judged as before accounts. An
    answer that names none is the replacement's when [child_pid] holds the
    announcement lock of the port: [port_holder] is
    {!Server_startup_takeover.account_server_port_holder} for that port, and
    is asked once. Without a ready answer nothing is asked: a process that
    announces and does not answer is not ready. *)
