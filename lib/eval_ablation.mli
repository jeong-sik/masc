(** Eval_ablation — Component ablation testing infrastructure.

    Compares evaluation suite results with and without specific
    components to measure each component's contribution.
    Uses two-proportion z-test for statistical significance.

    Components are classified as:
    - [Model_compensating]: scaffolding that compensates for model limitations
    - [Coordination]: distributed systems infrastructure (not ablation targets)

    @since #3074 *)

(** {1 Component classification} *)

type component_class =
  | Model_compensating
  | Coordination

type component = {
  name : string;
  description : string;
  classification : component_class;
  disable_fn : string;
}

val component_class_to_string : component_class -> string

val registry : component list
(** Built-in component registry with classification. *)

val ablatable_components : unit -> component list
(** Components classified as [Model_compensating]. *)

val find_component : string -> component option
(** Lookup by name. *)

(** {1 Statistical testing} *)

val two_proportion_z_test :
  x1:int -> n1:int -> x2:int -> n2:int -> float * float
(** [two_proportion_z_test ~x1 ~n1 ~x2 ~n2] returns [(z_stat, p_value)].
    Two-tailed test using normal approximation. *)

(** {1 Ablation results} *)

type scenario_comparison = {
  scenario_id : string;
  scenario_name : string;
  baseline_pass_at_k : float;
  ablated_pass_at_k : float;
  baseline_mean_score : float;
  ablated_mean_score : float;
  lift : float;
  z_stat : float;
  p_value : float;
  significant : bool;
}

type ablation_result = {
  component : component;
  alpha : float;
  comparisons : scenario_comparison list;
  overall_lift : float;
  significant_count : int;
  verdict : string;
}

(** {1 Comparison} *)

val compare_suites :
  component:component ->
  ?alpha:float ->
  baseline:Eval_harness.eval_suite_result ->
  ablated:Eval_harness.eval_suite_result ->
  unit -> ablation_result
(** Compare baseline and ablated suite results. *)

val run_all_ablations :
  ?alpha:float ->
  run_suite:(?disable:string -> unit -> Eval_harness.eval_suite_result) ->
  unit -> ablation_result list
(** Run ablation for all model-compensating components. *)

(** {1 Serialization} *)

val scenario_comparison_to_json : scenario_comparison -> Yojson.Safe.t
val ablation_result_to_json : ablation_result -> Yojson.Safe.t
val report_to_string : ablation_result -> string
