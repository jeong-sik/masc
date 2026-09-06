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

let operator_surface_to_string = function
  | Primary -> "primary"
  | Fragment -> "fragment"
;;

let operator_surface_of_string = function
  | "primary" -> Some Primary
  | "fragment" -> Some Fragment
  | _ -> None
;;

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

(* Resolution and the text it selects, together, because they are one
   decision: the source is which of the two values won. Kept apart, the same
   four lines were written twice in prompt_registry.ml and could drift into
   a source that names a value the caller did not take. *)
let resolve_source ~override_value ~file_value =
  match override_value with
  | Some value -> (Override, value)
  | None -> (
    match file_value with
    | Some value -> (File, value)
    | None -> (Missing, ""))

let prompt_source_to_string = function
  | Override -> "override"
  | File -> "file"
  | Missing -> "missing"

