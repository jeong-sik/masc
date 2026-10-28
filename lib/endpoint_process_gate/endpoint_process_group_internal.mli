(** Private implementation of a newly-created, controller-owned cgroup v2.
    The public subset is Endpoint_process_gate.Group. Not a durable registry or
    namespace sandbox. No existing group, PID, process group or file is adopted. *)
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
(** Explicit trusted parent, protected root-owned ancestors, actual cgroup2
    filesystem, exclusive new mode0700 leaf and pinned physical identity.
    The owner switch must outlive every spawn. No automatic cgroup mount,
    controller configuration or fallback when delegation is unavailable. *)

val populated : t -> (bool, error) result
(** Original recursive kernel observation; false is not a payload result. *)
val kill_tree : t -> (unit, error) result
(** Retire admission before requesting cgroup.kill on this original tree.
    Idempotent while retiring; this is a request, not empty/exit/output proof. *)
val await_empty : t -> (unit, error) result
(** Each call opens its own events cursor and registers its own epoll before
    reading that cursor. Public observations and other waiters cannot consume
    its pending transition. Cancellable event wait without a blocked system-thread waiter. Waiter
    cancellation preserves the group and payload. Before retirement, emptiness
    is only an observation and does not prevent future admitted children. *)
val release : t -> (unit, error) result
(** Endpoint-owner teardown: retire, request tree kill, await actual recursive
    emptiness, remove only the pinned new group, close private handles. Errors
    stay visible. This does not reap original mains or seal output/results. *)

val with_spawn : t -> (Unix.file_descr -> 'a) -> ('a, error) result
(** PRIVATE to this library. Hold this group's bounded admission boundary
    through clone3(CLONE_INTO_CGROUP). The borrowed descriptor is never returned
    by the public Group API. Callback must register child ownership and return
    before waiting for payload completion; cancellation/exceptions propagate
    without poisoning cleanup. No caller-supplied existing FD is adopted. *)

module For_testing : sig
  val linux_build : bool
  val await_empty : after_populated:(bool -> unit) -> t -> (unit, error) result
  (** The hook runs after each private observation, outside the group lock,
      before waiting when populated. It may perform cancellable Eio effects. *)
end
