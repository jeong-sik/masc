(** Session-owned terminal results for workspace readers and retained operations. Shared
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
