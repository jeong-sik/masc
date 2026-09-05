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

(** Where a prompt's effective text came from. Resolution is override, then
    file, then neither, and these three are the whole answer -- the word that
    goes on the wire is {!prompt_source_to_string} of one of them. *)
type prompt_source =
  | Override
  | File
  | Missing

type prompt_resolution = {
  effective : string;
  source : prompt_source;
  file_value : string option;
  override_value : string option;
  file_path : string option;
  file_exists : bool;
  has_override : bool;
}

val resolve_source :
  override_value:string option ->
  file_value:string option ->
  prompt_source * string
(** The source and the text it selects. One decision, so one function: the
    source names which of the two values the caller is being handed. *)

val prompt_source_to_string : prompt_source -> string
(** The word the HTTP surfaces have always sent: ["override"], ["file"],
    ["missing"]. *)
