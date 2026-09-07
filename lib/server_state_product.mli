(** Orthogonal state machine composition — Server Lifecycle x LazyTaskQueue x
    Readiness.

    Three independent FSMs composed into a product state with cross-dimension
    invariant checking. Each dimension evolves independently; synchronization
    happens only at explicit guard points.

    Follows the UML orthogonal regions pattern and
    [specs/server-state/ServerState.tla].

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

  type event =
    | Boot_complete
    | Start_draining
    | Stop

  val event_to_string : event -> string

  type transition = Applied of phase | Ignored of { phase: phase; event: event }

  val apply_event : current:phase -> event -> transition
  val pp_phase : Format.formatter -> phase -> unit
end

(** {2 Dimension 2: Lazy Task Queue} *)

module Lazy_task_queue : sig
  type t =
    | Complete      (** All lazy tasks finished *)
    | Pending of string list  (** Tasks still pending *)

  val to_string : t -> string

  type event =
    | Tasks_appear of string list
    | Task_finish of string
    | Task_fail of { task: string; error: string }

  val apply_event : current:t -> event -> t
  val pp : Format.formatter -> t -> unit
end

(** {3 Dimension 3: Readiness} *)

module Readiness : sig
  type phase =
    | NotReady      (** Not accepting traffic *)
    | Ready         (** Accepting traffic *)

  val phase_to_string : phase -> string

  type event =
    | Set_ready
    | Set_not_ready

  type transition = Applied of phase | Ignored of { phase: phase; event: event }

  val apply_event : current:phase -> event -> transition
  val pp_phase : Format.formatter -> phase -> unit
end

(** {4 Product State} *)

type product = {
  lifecycle : Lifecycle.phase;
  lazy_tasks : Lazy_task_queue.t;
  readiness : Readiness.phase;
  last_error : string option;
}

val initial : product

(** {5 Cross-Dimension Invariants} *)

val check_invariants : product -> (unit, string) result

(** {6 Per-Dimension Event Application} *)

val apply_lifecycle_event :
  product -> Lifecycle.event -> (product, string) result

val apply_lazy_event :
  product -> Lazy_task_queue.event -> (product, string) result

val apply_readiness_event :
  product -> Readiness.event -> (product, string) result

(** {7 Derived Flat Phase} *)

type flat_phase =
  | Blocking
  | Lazy
  | Ready
  | Degraded

val derive_flat_phase : product -> flat_phase
val flat_phase_to_string : flat_phase -> string
val pp_flat_phase : Format.formatter -> flat_phase -> unit

(** {8 Serialization} *)

val product_to_json : product -> Yojson.Safe.t
