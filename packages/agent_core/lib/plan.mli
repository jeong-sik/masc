(** Plan — goal decomposition and adaptive execution.

    Decomposes a high-level goal into ordered steps, tracks progress,
    and supports re-planning when steps fail or conditions change.

    Plan handles typed goal decomposition and re-planning without owning the
    agent execution lifecycle.

    @since 0.77.0

    @stability Evolving
    @since 0.93.1 *)

(** {1 Step status} *)

type step_status =
  | Pending
  | Running
  | Done
  | Failed of string
  | Skipped

(** {1 Plan step} *)

type step =
  { id : string
  ; description : string
  ; status : step_status
  ; result : Yojson.Safe.t option
  ; depends_on : string list (** ids of steps this depends on *)
  }

(** {1 Plan status} *)

type plan_status =
  | Planning
  | Executing
  | Replanning
  | Completed
  | Abandoned of string

(** {1 Plan} *)

type t

(** Create a new plan with the given goal. *)
val create : goal:string -> planner:string -> unit -> t

(** {1 Step management} *)

(** Add a step to the plan. Steps execute in insertion order,
    respecting [depends_on] constraints. *)
val add_step
  :  t
  -> id:string
  -> description:string
  -> ?depends_on:string list
  -> unit
  -> t

(** Mark a step as running. *)
val start_step : t -> string -> t

(** Mark a step as done with a result. *)
val complete_step : t -> string -> result:Yojson.Safe.t -> t

(** Mark a step as failed. *)
val fail_step : t -> string -> reason:string -> t

(** Skip a step. *)
val skip_step : t -> string -> t

(** {1 Re-planning} *)

(** Replace all [Pending] steps with new steps.
    [Running] and [Done] steps are preserved.
    Plan status transitions to [Replanning] then back to [Executing]. *)
val replan : t -> new_steps:step list -> t

(** {1 Plan transition guards} *)

type plan_transition_error =
  | InvalidPlanTransition of
      { from_status : plan_status
      ; to_status : plan_status
      }
  | PlanAlreadyTerminal of { status : plan_status }

val is_terminal_status : plan_status -> bool
val valid_plan_transitions : plan_status -> plan_status list
val can_transition_to : plan_status -> plan_status -> bool
val transition_plan : t -> plan_status -> (t, plan_transition_error) result
val plan_transition_error_to_string : plan_transition_error -> string

(** {1 Plan lifecycle} *)

(** Transition plan to Executing. *)
val start : t -> t

(** Mark plan as Completed (all steps done/skipped). *)
val finish : t -> t

(** Abandon the plan with a reason. *)
val abandon : t -> reason:string -> t

(** {1 Queries} *)

val goal : t -> string
val planner : t -> string
val status : t -> plan_status
val steps : t -> step list
val step_count : t -> int
val current_step : t -> step option
val find_step : t -> string -> step option

(** Progress as 0.0 to 1.0 (done+skipped / total). *)
val progress : t -> float

(** Check if plan is terminal (Completed or Abandoned). *)
val is_done : t -> bool

(** Check if all dependencies of a step are satisfied (Done). *)
val deps_satisfied : t -> string -> bool

(** {1 Serialization} *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val step_status_to_string : step_status -> string
val plan_status_to_string : plan_status -> string
