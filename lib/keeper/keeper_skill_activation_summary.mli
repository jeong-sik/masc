(** Pure summaries of canonical activation and rejection evidence. *)
open Keeper_skill_activation_types

val summarize :
  activations:activation list ->
  transition_rejections:transition_rejection list -> summary
val summarize_by_scope :
  activations:activation list ->
  transition_rejections:transition_rejection list -> scoped_summary list
val summary_to_yojson : summary -> Yojson.Safe.t
val scoped_summary_to_yojson : scoped_summary -> Yojson.Safe.t
