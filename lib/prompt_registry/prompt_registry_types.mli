(** Prompt registry types — entries, metadata, resolution. *)

type prompt_entry = {
  id : string;
  template : string;
  version : string;
  variables : string list;
  created_at : float;
}

type operator_surface =
  | Primary
  | Fragment

val operator_surface_to_string : operator_surface -> string
val operator_surface_of_string : string -> operator_surface option

type prompt_meta = {
  description : string;
  category : string;
  operator_surface : operator_surface;
  required_file : bool;
  template_variables : string list;
}

type prompt_resolution = {
  effective : string;
  source : string;
  file_value : string option;
  override_value : string option;
  file_path : string option;
  file_exists : bool;
  has_override : bool;
}
