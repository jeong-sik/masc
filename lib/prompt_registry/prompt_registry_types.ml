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

type authoring_issue =
  | Invalid_operator_surface of { value : string; source_file : string }

type prompt_meta = {
  description : string;
  category : string;
  operator_surface : operator_surface;
  authoring_issues : authoring_issue list;
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

let prompt_source_of_string = function
  | "override" -> Some Override
  | "file" -> Some File
  | "missing" -> Some Missing
  | _ -> None

let prompt_resolution_members =
  [ "effective"; "source"; "file_value"; "override_value"; "file_path";
    "file_exists"; "has_override" ]

let prompt_resolution_to_yojson (p : prompt_resolution) : Yojson.Safe.t =
  `Assoc
    [ ("effective", `String p.effective);
      ("source", `String (prompt_source_to_string p.source));
      ("file_value", Json_util.string_opt_to_json p.file_value);
      ("override_value", Json_util.string_opt_to_json p.override_value);
      ("file_path", Json_util.string_opt_to_json p.file_path);
      ("file_exists", `Bool p.file_exists);
      ("has_override", `Bool p.has_override) ]

let prompt_resolution_of_yojson (json : Yojson.Safe.t) =
  let ( let* ) = Result.bind in
  let invalid detail = Error ("prompt resolution " ^ detail) in
  match json with
  | `Assoc members
    when List.sort String.compare (List.map fst members)
         = List.sort String.compare prompt_resolution_members ->
    let text key =
      match List.assoc key members with
      | `String value -> Ok value
      | _ -> invalid (key ^ " expects text")
    in
    let text_or_null key =
      match List.assoc key members with
      | `Null -> Ok None
      | `String value -> Ok (Some value)
      | _ -> invalid (key ^ " expects text or null")
    in
    let flag key =
      match List.assoc key members with
      | `Bool value -> Ok value
      | _ -> invalid (key ^ " expects a boolean")
    in
    let* effective = text "effective" in
    let* source_word = text "source" in
    let* source =
      match prompt_source_of_string source_word with
      | Some source -> Ok source
      | None -> invalid "source is not override, file or missing"
    in
    let* file_value = text_or_null "file_value" in
    let* override_value = text_or_null "override_value" in
    let* file_path = text_or_null "file_path" in
    let* file_exists = flag "file_exists" in
    let* has_override = flag "has_override" in
    Ok { effective; source; file_value; override_value; file_path;
         file_exists; has_override }
  | _ ->
    invalid "has unknown, duplicate or missing members"

