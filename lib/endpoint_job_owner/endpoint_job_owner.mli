(** Original-operation controller inside an independently owned endpoint.
    All records and permits come from one configured protected registry.
    Peer authentication, wire dispatch, host admission/consumption and Release
    are separate obligations; IDs and this library do not authenticate a peer.
    Scheduling/control calls run in the endpoint Switch's Eio domain. *)
module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module L = Endpoint_job_launch
module C = Endpoint_job_lifetime
module D = Endpoint_job_result
type t
type operation
type request
type error =
  | Registry_error of R.error
  | Launch_error of L.error
  | Lifetime_error of C.error
  | Result_error of D.error
  | Binding_mismatch
  | Admission_mismatch
  | Launch_unknown
  | Result_digest_mismatch
  | Execution_unavailable of string
  | Owner_stopped
  | Controller_failed of exn
val error_to_string : error -> string
val create :
  sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> registry:R.t ->
  cgroup_parent_path:string -> new_id:(unit -> P.Id.t) ->
  resolve_execution:(P.spec -> (L.execution,string) result) -> t
(** The Switch is the endpoint lifetime, never a request, model turn or host
    server connection. Resolution is trusted policy, not forwarded controls;
    it runs only for an original not yet owned by a native supervisor.
    Fresh IDs come from the controller, never a peer's claimed historical ID.

    Every original keeps one table entry, one actor and one release hook until
    this Switch ends, including after its result is final; nothing evicts them
    earlier (issue #46444). A failed control is reported to its observers.
    A later explicit control can resume a failed actor on the same operation,
    retaining its captured source, native lifetime and result. Failed controls
    are never replayed. Endpoint shutdown cannot be resumed. *)
val admit : t -> binding:P.binding -> spec:P.spec -> (operation,error) result
(** Register complete original bytes without launching. Existing live entries
    refresh their captured source; missing authority never falls back to admit.
    The host must durably retain this original before requesting activation. *)
val lookup : t -> P.original -> (operation,error) result
(** Bind the complete lookup/admission to this controller's original protected
    registry. Cold known launches remain unknown live ownership; this function
    creates neither a new admission nor a recovered kernel handle. Existing entries
    validate their captured physical original; a newly loaded matching binding
    never replaces it. Concurrent cold lookup/admission share one reservation. *)
val original : operation -> P.original
val inspect_original : operation -> (R.record,error) result
(** Current source only, without waiting for startup, process exit or output.
    This is not an execution or complete-result projection. A concurrent source
    advance returns [Registry_error R.Stale_record] instead of rolling it back. *)
val activate : operation -> request
val cancel : operation -> request
(** Reserve an endpoint-owned control and return before its I/O. Concurrent
    controls of the same kind share the active request. Each original actor
    serializes its own controls; pending cancellation wins before a pending
    activation. Other operations never join this actor's I/O or startup.
    A later explicit request revalidates the original. No implicit retry,
    deadline, lock polling, new admission or launch replay is introduced. *)
val await_request : request -> (unit,error) result
(** Observer cancellation does not cancel the accepted control. Activation
    success means a reserved original lifetime, never exec or result success.
    Cancellation success proves durable intent and an original kill request
    when a native owner exists, not physical settlement or consumed output. *)
val await_result : operation -> (P.Sha256.t,error) result
(** Event-driven historical publication digest. Registration-only cancellation
    publishes through actual opaque no-child authority; no OS launch outcome
    is invented. Unavailable activation is a visible hold. A later explicit
    activation/cancellation can update the observation without changing the
    original. Cold known launches return Launch_unknown rather than waiting
    on an invented live future. Cancelling an observer leaves the actor alive. *)
val load_result :
  sw:Eio.Switch.t -> expected_sha256:P.Sha256.t option -> operation -> (D.t,error) result
(** Load actual original storage and fully verify complete output/receipt.
    A live publication binds its known digest; Some host digest must agree.
    Cold discovery with None uses protected storage only, never live ownership.
    Reader resources belong to this observer. No host ACK or cleanup granted. *)

module For_testing : sig
  val create :
    before_request:(unit -> unit) ->
    sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> registry:R.t ->
    cgroup_parent_path:string -> new_id:(unit -> P.Id.t) ->
    resolve_execution:(P.spec -> (L.execution,string) result) -> t
  (** Inject an exception outside request handling to observe controller failure
      and explicit recovery. This grants no execution or registry authority. *)
  val inspect_original : after_refresh:(unit -> unit) -> operation -> (R.record,error) result
  (** Interleave after the actual captured-source refresh and before adopting its
      result. A concurrently advanced source remains pinned; no retry occurs. *)
  val await_startup : operation -> ((C.S.launch_outcome,error) result) option
  (** Observe an owned native lifetime's actual startup future. None means no
      native lifetime exists; this neither activates nor reconstructs one. *)
end
