(** Original endpoint launch rendezvous: registry permit, protected storage,
    kernel tree and paused child, with durable intent before activation.

    This is the trusted supervisor core, not an authenticated endpoint or
    backend advertisement. It accepts only Workspace_process/Effect with no
    extra network policy. Observe, Guest_local and isolated jobs need their
    actual boundary implementation and are refused here. The caller still
    authorizes the peer, executable, path jail, environment and endpoint policy.
    No original process is reconstructed from journal files or numeric PIDs. *)
module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module G = Endpoint_process_gate

type t
type execution =
  { executable : string
  ; env : string list
  ; cwd : string
  ; payload_gid : int
  }
(** Trusted endpoint resolution, not fields copied from a control request.
    The original argv and payload UID always come from the committed permit.
    The service supplies the original stdin and retains/drains stdout/stderr;
    this module neither certifies their bytes nor seals output. *)

type error =
  | Scope_unavailable
  | Registry_error of R.error
  | Group_error of G.Group.error
  | Process_error of G.error
  | Codec_error of P.codec_error
  | Storage_unavailable
  | Publication_failed of Fs_compat.capability_write_error
  | Recovery_failed of string

val error_to_string : error -> string

val check_execution_domain : P.spec -> (unit,error) result
(** Pure domain/mode/network compatibility check shared with the trusted
    controller before committing launch intent. This grants no permission and
    does not verify native kernel, execution, peer or filesystem readiness.
    The native launcher rechecks the exact committed specification. *)

type activation = Requested | Held of error
val activation : t -> activation
val original : t -> P.original
val observe_original : t -> (R.record, error) result
(** Refresh the opaque original source captured by this launch. Matching caller
    coordinates cannot substitute another registry or known launch. This read
    grants no new effect or recovered kernel-handle authority. *)
val specification : t -> P.spec
val storage : t -> Eio.Fs.dir_ty Eio.Path.t
(** The same original capability owned by the job Switch, for the trusted
    supervisor's output/result publication. Never reopen its pathname. *)
val with_storage_publication : t -> (unit -> 'a) -> 'a
(** Serialize bounded metadata publications under this actual owner's storage,
    including publication-recovery setup. Acquisition remains cancellable; once
    acquired, finish the short callback under cancellation protection, unlock,
    then check the original cancellation context. Exceptions unlock without
    poisoning future operations. Fs owns
    transaction recovery, so there is no partial shared in-memory transaction.
    Never hold this lock across source reads, capture, hashing or EOF waits. *)
val rendezvous_leaf : string
val activation_leaf : string

val launch_effect_workspace :
  sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t ->
  cgroup_parent_path:string -> execution:execution ->
  stdin:Unix.file_descr -> stdout:Unix.file_descr -> stderr:Unix.file_descr ->
  R.launch_intent -> (t, error) result R.launch_outcome
(** [sw] is the independent per-job lifetime, never a client/model-turn switch.
    The borrowed stdio descriptors must remain valid until this returns or
    raises. Registration and launch intent already exist. Under that job's
    nonwaiting lock, create a new cgroup and original paused child, wait for
    kernel setup, durably publish its complete rendezvous and activation intent,
    then request gate activation. The callback does not wait for payload exit.
    Native preparation/readiness and source work remain cancellable. Only
    entered Fs recovery setup and each bounded metadata publication/cleanup are
    protected; pending cancellation prevents activation and propagates after
    the original job lock is released.

    Once a child exists, a typed startup failure returns its original owner
    as [Ok t] with [Held error], preserving its handles for cancellation and
    reconciliation. [Requested] means a gate request, never exec success or
    complete output. Exceptions/cancellation propagate with the permit spent
    and resources still owned by [sw]. No restart or lost reply grants replay.
    Journal coordinates alone never restore lost kernel wait/signal authority. *)

val cancel : t -> (R.record, error) result
(** Revalidate through the opaque original record captured by the launch permit,
    preserving its exact registry, admission, job and known launch identity.
    Commit cancellation before retiring/killing its exact
    original kernel tree. A returned record proves durable intent plus a kill
    request, not termination. Missing/replaced authority issues no signal. *)

val await_quiescent : t -> (G.exit_observation, error) result
(** Cancellable original-main reap plus actual recursive tree emptiness.
    Cancellation of this waiter leaves the job alive. The raw physical status
    may be a bootstrap exit: this does not create a protocol terminal result,
    seal output or acknowledge result consumption. *)

module For_testing : sig
  val launch_effect_workspace :
    after_rendezvous:(unit -> unit) ->
    sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t ->
    cgroup_parent_path:string -> execution:execution ->
    stdin:Unix.file_descr -> stdout:Unix.file_descr -> stderr:Unix.file_descr ->
    R.launch_intent -> (t, error) result R.launch_outcome
  (** Actual paused child and durable rendezvous, before activation intent. *)
  val cancel :
    after_intent:(R.record -> unit) -> t -> (R.record, error) result
  (** Actual committed cancellation, before the original tree kill request. *)
end
