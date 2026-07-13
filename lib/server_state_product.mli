(** Orthogonal state machine composition — Server Lifecycle x Backend x
    LazyTaskQueue x Readiness.

    Four independent FSMs composed into a product state with cross-dimension
    invariant checking. Each dimension evolves independently; synchronization
    happens only at explicit guard points.

    Follows the UML orthogonal regions pattern. Mirrors
    {!State_product} conventions and [specs/server-state/ServerState.tla].

    Current mode: enforcing — invariant violations return [Error].

    @since 2.260.0 *)

(** {1 Dimension 1: Lifecycle} *)

module Lifecycle : sig
  type phase =
    | Booting       (** Server is starting, HTTP not serving yet *)
    | Serving       (** HTTP accept loop active, processing requests *)
    | Draining      (** Graceful shutdown in progress, no new work *)
    | Stopped       (** Server has shut down *)

  val phase_to_string : phase -> string
  val all_phases : phase list

  type event =
    | Boot_complete
    | Start_draining
    | Stop

  val event_to_string : event -> string

  type transition = Applied of phase | Ignored of { phase: phase; event: event }

  val apply_event : current:phase -> event -> transition
  val apply_event_lossy : current:phase -> event -> phase
  val pp_phase : Format.formatter -> phase -> unit
end

(** {2 Dimension 2: Backend} *)

module Backend : sig
  type phase =
    | Uninitialized (** Backend not yet resolved *)
    | Memory        (** In-process fallback backend *)
    | Filesystem    (** Fallback to filesystem backend *)
    | Degraded      (** Backend connection failed *)

  val phase_to_string : phase -> string
  val all_phases : phase list

  type event =
    | Resolve_memory
    | Resolve_fs
    | Degrade of string
    | Recover

  val event_to_string : event -> string

  type transition = Applied of phase | Ignored of { phase: phase; event: event }

  val apply_event : current:phase -> event -> transition
  val apply_event_lossy : current:phase -> event -> phase
  val pp_phase : Format.formatter -> phase -> unit
end

(** {3 Dimension 3: Lazy Task Queue} *)

module Lazy_task_queue : sig
  type t =
    | Complete      (** All lazy tasks finished *)
    | Pending of string list  (** Tasks still pending *)

  val to_string : t -> string
  val all_states : t list

  type event =
    | Tasks_appear of string list
    | Task_finish of string
    | Task_fail of { task: string; error: string }

  val event_to_string : event -> string

  val apply_event : current:t -> event -> t
  val pp : Format.formatter -> t -> unit
end

(** {4 Dimension 4: Readiness} *)

module Readiness : sig
  type phase =
    | NotReady      (** Not accepting traffic *)
    | Ready         (** Accepting traffic *)

  val phase_to_string : phase -> string
  val all_phases : phase list

  type event =
    | Set_ready
    | Set_not_ready

  val event_to_string : event -> string

  type transition = Applied of phase | Ignored of { phase: phase; event: event }

  val apply_event : current:phase -> event -> transition
  val apply_event_lossy : current:phase -> event -> phase
  val pp_phase : Format.formatter -> phase -> unit
end

(** {5 Product State} *)

type product = {
  lifecycle : Lifecycle.phase;
  backend : Backend.phase;
  lazy_tasks : Lazy_task_queue.t;
  readiness : Readiness.phase;
  last_error : string option;
  fallback_reason : string option;
}

val initial : product

(** {6 Cross-Dimension Invariants} *)

val check_invariants : product -> (unit, string) result

(** {7 Per-Dimension Event Application} *)

val apply_lifecycle_event :
  product -> Lifecycle.event -> (product, string) result

val apply_backend_event :
  product -> Backend.event -> (product, string) result

val apply_lazy_event :
  product -> Lazy_task_queue.event -> (product, string) result

val apply_readiness_event :
  product -> Readiness.event -> (product, string) result

(** {8 Derived Flat Phase (backward compatibility)} *)

type flat_phase =
  | Blocking
  | Lazy
  | Ready
  | Degraded

val derive_flat_phase : product -> flat_phase
val flat_phase_to_string : flat_phase -> string
val pp_flat_phase : Format.formatter -> flat_phase -> unit

(** {9 Serialization} *)

val product_to_json : product -> Yojson.Safe.t
