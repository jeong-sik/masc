(** The standalone lanes: model-driven exact-output work that runs outside a
    Keeper turn. A lane is one [\[runtime.exact_output_lanes.<id>\]] table, one
    row of the standalone-lane projection, and the [lane] a run record names.

    [Runtime.exact_lane] and [Exact_lane_run_registry.lane] are this type, so
    adding a lane here fails every match that has not yet said what the new
    lane means. *)

type t =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Workspace_curator
  | Verifier

val all : t list
(** Every lane once, in declaration order. *)

val to_id : t -> string
(** The lane's id: its table key in the runtime file, the [lane_id] the
    standalone-lane projection serves, and the [lane] a run record carries.
    Code that sends, stores or compares a lane id takes it from here. *)

val of_id : string -> t option
(** The lane whose {!to_id} is the argument. An id no lane has is [None]. *)
