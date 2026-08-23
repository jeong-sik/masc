(** Provider-attempt provenance and health helpers for keeper turn driver. *)


let success_selected_model_raw candidate =
  Some (Runtime_candidate.model_health_key candidate)

let runtime_candidate_label = "runtime"
