(** Keeper feature catalog used by the dashboard feature-proof read model. *)

type feature_spec = {
  id : string;
  label : string;
  required_tools : string list;
  next_action : string;
}

val tool_features : feature_spec list
