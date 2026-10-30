(** An endpoint controller's original main-process handle and activation gate.

    Linux clone3 creates the pidfd atomically with the child. Before activation
    the child resets inherited signals, closes other descriptors, drops to the
    explicit distinct non-root UID and explicit GID, clears capabilities, applies no-new-privs
    and waits on its private gate. No OCaml code runs in the cloned child.

    This is a process primitive, not an authenticated async backend. The caller
    owns the executable/path jail, network/filesystem/namespace policy, original
    registry rendezvous, process-tree containment and durable output/exit receipt.
    Root payloads need a measured namespace boundary in that supervisor. *)
module Group : sig
  type t
  type protection =
    | Controller_not_root | Invalid_parent | Invalid_name | Unsafe_ancestor
    | Not_cgroup_v2 | Group_identity_changed | Group_not_private
  type stage =
    | Allocate | Open_parent | Create_group | Open_group | Open_events
    | Create_watch | Read_events | Kill_tree | Remove_group | Close_group | Close_watch
  type error =
    | Unsupported | Refused of protection | Syscall_failed of { stage : stage; error : Unix.error }
    | Protocol_error | Malformed_events | Retiring | Closed
    | Cleanup_failed of { primary : error option; error : Unix.error }
  val error_to_string : error -> string
  exception Release_failed of error
  val create : sw:Eio.Switch.t -> parent_path:string -> name:string -> (t, error) result
  (** Create a new root-owned mode0700 cgroup v2 under an explicit protected
      parent; exclusive creation and pinned kernel/filesystem identity only.
      No existing group is adopted and no mount/controller setup is implicit. *)
  val populated : t -> (bool, error) result
  val kill_tree : t -> (unit, error) result
  (** Retire new admission before cgroup.kill; a request is not termination. *)
  val await_empty : t -> (unit, error) result
  (** Cancellable event wait with a private events cursor and epoll per call.
      Other observations/waiters cannot acknowledge its pending transition.
      Cancelling a waiter preserves the payload.
      Actual recursive emptiness is not output sealing or payload exit proof. *)
  val release : t -> (unit, error) result
  (** Owner teardown requests tree kill, waits for actual recursive emptiness,
      removes only its original group and closes private descriptors. Original
      main-process reaping and complete output/result settlement stay separate.
      This ephemeral handle alone is not durable restart/registry authority. *)
end

type t

type invalid_input =
  | Executable | Arguments | Environment | Directory | Payload_uid | Payload_gid
  | Shared_uid | Controller_not_root

type stage =
  | Allocate | Duplicate_stdio | Open_directory | Create_gate | Mask_signals | Create_child
  | Child_descriptors | Child_close_descriptors | Child_session | Child_directory
  | Child_credentials | Child_capabilities | Child_signals | Child_ready | Child_gate | Child_exec
  | Control_io | Signal_main | Wait_main | Close_handle | Duplicate_watch | Duplicate_group

type error =
  | Unsupported
  | Group_error of Group.error
  | Invalid_input of invalid_input
  | Syscall_failed of { stage : stage; error : Unix.error }
  | Child_rejected of { stage : stage; error : Unix.error }
  | Protocol_error
  | Not_ready
  | Already_decided
  | Control_lost
  | Closed
  | Exit_unavailable
  | Cleanup_failed of { primary : error option; error : Unix.error }

val error_to_string : error -> string
exception Release_failed of error
(** A failed switch cleanup remains visible to its owner. *)

type decision = Undecided | Activate_requested | Abort_requested

type preparation = Pending | Ready | Rejected of { stage : stage; error : Unix.error }
type control_failure = Protocol_violation | Receive_failed of Unix.error
type control = Open | Ended | Failed of control_failure
type boundary = { preparation : preparation; decision : decision; control : control }
(** Ended is descriptor EOF/closure, not proof that exec succeeded. Failed is
    the first private-channel failure; nothing is read after it, so the other
    fields may be cut short and never prove a non-start. *)
val control_failure_error : control_failure -> error

type exit_status = Exited of int | Signaled of int
(** Signal numbers are actual host numbers, not OCaml's abstract signal codes. *)
type exit_observation = { status : exit_status; boundary : boundary }
(** This is the original OS child's physical status. Before activation, or if
    exec was rejected, it is a bootstrap exit and must not become a payload exit.
    Neither activation nor control EOF alone proves that a payload ran. *)

val create :
  sw:Eio.Switch.t -> executable:string -> argv:string array -> env:string array ->
  cwd:string -> payload_uid:int -> payload_gid:int ->
  stdin:Unix.file_descr -> stdout:Unix.file_descr -> stderr:Unix.file_descr ->
  (t, error) result
(** Eio-only. Creates a paused child in a system thread and registers ownership
    before cancellation can escape. Environment and stdio are explicit, with no
    implicit credential/environment inheritance. The argument/environment arrays
    are copied before validation or the first yield. Callers must not mutate
    them concurrently while that synchronous copy runs. Stdio descriptors are
    borrowed and must remain open and unreused until create returns or raises.
    No numeric PID or external handle is accepted or returned.

    [sw] MUST be endpoint-operation owned, not a control-connection/model-turn
    switch. Its teardown kills/reaps this original MAIN process using the pidfd;
    it is not a complete process-tree cancellation or output settlement contract.
    Unsupported kernels/platforms refuse instead of using a numeric PID fallback. *)

val create_in_group :
  group:Group.t -> sw:Eio.Switch.t -> executable:string -> argv:string array -> env:string array ->
  cwd:string -> payload_uid:int -> payload_gid:int ->
  stdin:Unix.file_descr -> stdout:Unix.file_descr -> stderr:Unix.file_descr ->
  (t, error) result
(** The same original gate, born directly into the original live group using
    clone3(CLONE_INTO_CGROUP); no PID migration or host/group fallback. Group
    retirement and this bounded spawn serialize per group, never globally.
    Caller retains the exact sandbox/credential/path/network authority duties. *)

val observe_boundary : t -> (boundary, error) result
(** Nonblocking; consumes/caches private child setup/error observations. A
    failed channel is reported as control=Failed, not as an error. *)
val await_ready : t -> (unit, error) result
(** Cancellable Eio wait. Cancelling this waiter never cancels the child. A
    failed channel is an error here, before any preparation. *)
val activate : t -> (unit, error) result
val abort : t -> (unit, error) result
(** A single gate decision. Abort can precede readiness. Repeating/changing a
    decision is refused. A supervisor must commit its original rendezvous or
    cancellation intent before the corresponding effect. *)

type termination = Terminate | Kill
type signal_result = Requested | Already_exited
val signal_main : t -> termination -> (signal_result, error) result
(** Only the original pidfd is signalled. Requested is not termination proof.
    Descendants are outside this primitive; no PID/group fallback exists. *)
val poll_exit : t -> (exit_observation option, error) result
(** None means the original child has not been reaped by this owner yet.
    Lost wait authority is an error, never a successful exit or fresh PID lookup. *)
val await_exit : t -> (exit_observation, error) result
(** Cancellable Eio wait; the cached original status survives reaping. A private
    control failure seen after the reap is kept in its boundary as Failed. *)
val release : t -> (exit_observation, error) result
(** Explicit endpoint-owner teardown: SIGKILL the original main process, reap
    through its pidfd and close private descriptors. Idempotent after settlement.
    If the signal fails, the descriptors still close without a reap and that
    failure is the settlement.
    It does not claim descendant cleanup, complete output or Task/Goal success. *)

module For_testing : sig
  val await_group_empty :
    after_populated:(bool -> unit) -> Group.t -> (unit, Group.error) result
  (** Pause after a private population observation and before the event wait.
      Runs outside the group lock and permits cancellable Eio effects. *)
  val create :
    before_spawn_in_worker:(unit -> unit) ->
    sw:Eio.Switch.t -> executable:string -> argv:string array -> env:string array ->
    cwd:string -> payload_uid:int -> payload_gid:int ->
    stdin:Unix.file_descr -> stdout:Unix.file_descr -> stderr:Unix.file_descr ->
    (t, error) result
  (** Interrupt the actual worker before native capture. The hook must not
      perform Eio effects; exceptions propagate before any child exists. *)
  val linux_build : bool
  (** Compilation platform only, never a functioning kernel capability probe. *)
  val release_with_signal_failure : Unix.error -> t -> (exit_observation, error) result
  (** [release] whose original pidfd signal fails with this error. The wait,
      close and settlement cache are the real ones. *)
  val await_exit_with_control_failure : Unix.error -> t -> (exit_observation, error) result
  (** [await_exit] whose private control receives fail with this error. The
      pidfd wait and reap are the real ones. *)
end
