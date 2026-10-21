(** Session-owned partial observations and terminal results for workspace readers
    and retained operations. Shared
    notification capacity is not authority to retain a result or a launch error. *)
type 'message t

type 'message ready = { ready_at_ns : int64; message : 'message }

val create : unit -> 'message t
val take_ready : 'message t -> 'message ready list
(** Claim one finite FIFO batch in publication order. Pending jobs remain;
    later publications belong to a later batch. A claimed message still needs
    its original workspace/source/ticket admission at the UI. *)
val close : 'message t -> unit
(** End this exact session lifetime. Retire pending registrations and release
    unclaimed messages. New work and late publication cannot reopen it. Does
    not cancel workers or retract an already claimed batch. *)

val launch :
  ?key:unit ref -> ?observation:bool ->
  ?observe_job:(Masc_tui_workspace_job.event -> unit) ->
  ?on_not_run:(unit -> unit) ->
  Masc_tui_types.state -> results:'message t ->
  boundary_error:(string -> 'error) ->
  deliver:(('a, 'error) result -> 'message) ->
  (unit -> ('a, 'error) result) -> unit
(** Register before dispatch, preserve typed read/effect failures, and publish
    the formed completion without waiting for the bounded notification queue.
    No-switch/synchronous launch failure runs [on_not_run] then publishes the
    existing boundary error. A closed result owner starts no work and invokes
    [on_not_run] without forming a message for the ended session.

    Cancellation propagates without synthesizing success/failure. Worker and
    synchronous-launch cleanup retire only an unpublished registration; an
    already published result remains until claimed or session close. Actual
    workspace-job cancellation/registration ownership stays with the existing
    job implementation. [deliver] constructs the original message and scope;
    effects and response application are not performed by this registry.

    Work, callbacks, dispatch and cleanup may still block or fail. This only
    removes the mandatory completion wait on shared notification capacity. *)

val launch_session :
  results:'message t ->
  boundary_error:(string -> 'error) ->
  deliver:(('a, 'error) result -> 'message) ->
  (unit -> ('a, 'error) result) -> unit
(** Use the same terminal publication/error/close contract on the original
    current Eio switch, without joining workspace cancellation registrations.
    Intended for operations whose original receipts must survive workspace
    withdrawal. This does not transfer work to another/root switch or extend
    that switch's lifetime; root/runtime cancellation still propagates.

    The caller retains its original pre-dispatch workspace checks, request
    contents and expected workspace in the receipt. No scope is added here.
    The UI must distinguish the operation receipt from any later observation;
    a retained receipt never authorizes refreshing a foreign workspace or
    repeating the operation. No-switch/ordinary synchronous launch errors are
    retained through the same queue-independent publication. *)

val launch_observation :
  ?key:unit ref ->
  ?observe_job:(Masc_tui_workspace_job.event -> unit) ->
  ?on_not_run:(unit -> unit) ->
  Masc_tui_types.state -> results:'message t ->
  boundary_error:(string -> 'error) ->
  not_started:(string -> 'error) ->
  cancelled:'message ->
  progress:('part -> 'message) ->
  deliver:(('a, 'error) result -> 'message) ->
  (('part -> unit) -> ('a, 'error) result) -> unit
(** One workspace observation publishes partial facts and its terminal result
    through the same original registration. Publications retain FIFO order and
    never wait for shared notification capacity. Publishing a part keeps the
    registration; terminal publication closes it. Late parts after settlement,
    withdrawal or session close cannot reopen it. Already published parts remain
    claimable until session close and still need original UI admission.

    [not_started] classifies a missing switch, which proves no producer entry.
    [boundary_error] classifies producer or ordinary dispatch exceptions; a
    dispatch error alone does not prove whether the producer entered. Neither
    cause is inferred from explanation text. Cancelled dispatch is the explicit
    cancellation observation, without assuming physical entry.
    [progress] only forms the original message/scope; no UI effects. Producer
    protocol validation, source ordering, received timestamps and source/error
    meaning remain with the caller. No coalescing, dropping or numeric cap.
    [cancelled] is the caller's already formed original terminal observation,
    including its captured source/request/scope and explicit cancellation cause.
    Raw cancellation (also before worker entry) publishes it once through that
    same registration, after any published parts, and still propagates the
    original cancellation/backtrace. It is never success or a mutation receipt.
    An ended result session discards it. The UI must admit/settle the original
    request; publication itself changes no UI state or source authority.

    [on_not_run] also releases caller metadata when the switch is already
    cancelled before dispatch or workspace withdrawal wins before worker entry.
    Actual worker cancellation, cleanup and ownership use the existing workspace
    job; a terminal observation is not physical
    registration-release proof. Work/callbacks may still block. *)
