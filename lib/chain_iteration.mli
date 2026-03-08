(** Chain Iteration - GoalDriven Iteration Variable Substitution *)

(** {1 Types} *)

(** Iteration context for GoalDriven loops *)
type iteration_ctx = {
  iteration: int;
  max_iterations: int;
  progress: float;
  last_value: float;
  goal_value: float;
  strategy: string option;
}

(** {1 Substitution} *)

val substitute_vars : string -> iteration_ctx option -> string
(** Substitute iteration-aware variables in prompt.
    Supports: {{iteration}}, {{max_iterations}}, {{progress}}, {{last_value}},
    {{goal_value}}, {{strategy}}, {{linear:start,end}}, {{step:v1,v2,...}} *)
