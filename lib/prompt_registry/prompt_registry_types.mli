(** Prompt registry types — metrics, entries, stats, metadata, resolution. *)

type prompt_metrics = {
  usage_count : int;
  avg_score : float;
  last_used : float;
}
[@@deriving yojson]

type prompt_entry = {
  id : string;
  template : string;
  version : string;
  variables : string list;
  metrics : prompt_metrics option;
  created_at : float;
  deprecated : bool;
}
[@@deriving yojson]

type registry_stats = {
  total_prompts : int;
  active_prompts : int;
  deprecated_prompts : int;
  most_used : string option;
  avg_usage : float;
}

type prompt_meta = {
  description : string;
  category : string;
  required_file : bool;
  template_variables : string list;
}

type prompt_resolution = {
  effective : string;
  source : string;
  file_value : string option;
  override_value : string option;
  default_value : string option;
  file_path : string option;
  file_exists : bool;
  has_override : bool;
}
