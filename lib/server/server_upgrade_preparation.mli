(** Explicit upgrade preparation for an existing owner, including older servers
    without the model-setup resume endpoint. No process starts or forced kills. *)
type t
type error = Invalid_health | Different_workspace | Admin_required | Owner_unavailable
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
(** Call only after the user selects replacement. Rechecks workspace/version and
    admin authentication immediately before identity-bound SIGTERM. Success is
    a request, not proof of drain. Caller waits for lease/port release and starts
    the replacement with the same workspace and existing authentication. *)

val close : t -> unit
val suggest_loopback_port : unit -> (int, error) result
(** OS-selected candidate, not a reserved port. Recheck conflicts at startup. *)

module For_testing : sig
  val prepare : sw:Eio.Switch.t -> base_path:string -> observe:(unit -> (string, error) result) ->
    authorize:(unit -> bool) ->
    capture:(unit -> (((unit -> (unit, error) result) * (unit -> unit)), error) result) ->
    (t, error) result
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
  | No_account_server
      (** Nothing holds the lease, or its owner announces nothing the kernel
          showed: the server of a single user, or an account server that has
          not announced yet. *)

val account_server :
  run_dir:string -> base_path:string -> port:int ->
  (account_server, Server_startup_takeover.owner_capture_error) result
(** Reads the kernel owner of the lease of [base_path] and compares it with
    the holder of the announcement lock of [port]. A lock that a process
    other than the owner holds on the announcement file is no account
    server, whichever byte it is on. The other port is read over the whole
    file ({!Server_startup_takeover.account_server_announcement}) and can be
    missed behind such a lock; the answer is then [No_account_server]. It
    signals nothing, and the pid is a number to show: {!stop_account_server}
    reads the owner again. An [Error] when the lease or the announcement
    cannot be read. *)

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
