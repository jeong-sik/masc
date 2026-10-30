(** Prompt registry types — metadata, resolution. *)

type operator_surface =
  | Primary
  | Fragment

val operator_surface_to_string : operator_surface -> string
val operator_surface_of_string : string -> operator_surface option

type authoring_issue =
  | Invalid_operator_surface of { value : string; source_file : string }
      (** The unrecognized frontmatter value and the Markdown source path
          captured by the reader. The prompt remains usable; this is metadata diagnosis,
          not a refusal to render or apply an override. *)

type prompt_meta = {
  description : string;
  category : string;
  operator_surface : operator_surface;
      (** Effective placement in the operator's prompt list. Invalid authored
          values keep the prompt visible as [Primary] and are retained below. *)
  authoring_issues : authoring_issue list;
      (** Issues captured from the file's metadata when it was registered,
          including for slots registered from that file. Empty for absent
          metadata and for recognized declarations. *)
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
    source names which of the two values the caller is being handed.

    [Missing] always comes with [""]. The pair type does not say so, and the
    alternative — a variant carrying the text — would store it twice, beside
    the [effective] field that already holds it. The invariant is held by
    this one function, which is why the two ladders it replaced are gone. *)

val prompt_source_to_string : prompt_source -> string
(** The word the HTTP surfaces have always sent: ["override"], ["file"],
    ["missing"]. *)
