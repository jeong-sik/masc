(** Provider-attempt provenance and health helpers for keeper turn driver. *)


let success_selected_model_raw candidate =
  Some (Runtime_candidate.selected_endpoint_label candidate)
