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
