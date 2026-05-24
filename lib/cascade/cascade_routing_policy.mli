(** Routing Policy — public interface. *)

type task_use =
  | Code_generation | Code_review | Quick_decision
  | Long_reasoning | Tool_execution | Conversation
[@@deriving show, eq]

val task_use_to_string : task_use -> string
val task_use_of_string : string -> task_use option
val task_use_of_legacy_logical_use : string -> task_use option

type task_routing_policy = {
  task : task_use;
  primary_tier_group : string;
  diversity : Cascade_phonebook_types.diversity_constraint option;
}
[@@deriving show, eq]

val default_routing_policies : task_routing_policy list
val policy_for_task : task_routing_policy list -> task_use -> task_routing_policy option
val resolve_models_for_task :
  Cascade_phonebook_types.cascade_phonebook ->
  task_routing_policy list ->
  task_use ->
  Cascade_phonebook_types.cascade_phonebook_model list
val satisfies_diversity :
  Cascade_phonebook_types.cascade_phonebook ->
  Cascade_phonebook_types.cascade_phonebook_tier_group ->
  Cascade_phonebook_types.diversity_constraint option ->
  Cascade_phonebook_types.cascade_phonebook_model ->
  bool
