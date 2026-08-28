open Result.Syntax

type package_id = string

type package_id_error =
  | Empty_package_id
  | Current_directory_package_id
  | Parent_directory_package_id
  | Package_id_contains_separator
  | Package_id_contains_nul

type content_revision = string

type revision_error =
  | Invalid_revision_length of { actual : int }
  | Invalid_revision_character of
      { index : int
      ; found : char
      }

type identity =
  { source_id : Skill_source_config.source_id
  ; package_id : package_id
  ; name : string
  }

type t =
  { identity : identity
  ; content_revision : content_revision
  }

type decode_error =
  | Expected_object of { field : string }
  | Expected_list of { field : string }
  | Missing_field of
      { object_name : string
      ; field : string
      }
  | Expected_string of
      { object_name : string
      ; field : string
      }
  | Duplicate_field of
      { object_name : string
      ; field : string
      }
  | Unexpected_field of
      { object_name : string
      ; field : string
      }
  | Invalid_source_id of string
  | Invalid_package_id of package_id_error
  | Invalid_content_revision of revision_error
  | Duplicate_reference of t

let package_id_of_directory directory =
  if String.equal directory ""
  then Error Empty_package_id
  else if String.equal directory "."
  then Error Current_directory_package_id
  else if String.equal directory ".."
  then Error Parent_directory_package_id
  else if String.contains directory '/' || String.contains directory '\\'
  then Error Package_id_contains_separator
  else if String.contains directory '\000'
  then Error Package_id_contains_nul
  else Ok directory
;;

let package_id_to_string package_id = package_id

let validate_revision_string value =
  let expected_length = 64 in
  let actual = String.length value in
  if actual <> expected_length
  then Error (Invalid_revision_length { actual })
  else
    let rec validate index =
      if index = actual
      then Ok ()
      else
        match value.[index] with
        | '0' .. '9' | 'a' .. 'f' -> validate (index + 1)
        | found -> Error (Invalid_revision_character { index; found })
    in
    validate 0
;;

let content_revision_of_string value =
  Result.map (fun () -> value) (validate_revision_string value)
;;

let digest_fields fields =
  let buffer = Buffer.create (List.length fields) in
  List.iter
    (fun (tag, value) ->
       Buffer.add_string buffer (string_of_int (String.length tag));
       Buffer.add_char buffer ':';
       Buffer.add_string buffer tag;
       Buffer.add_string buffer (string_of_int (String.length value));
       Buffer.add_char buffer ':';
       Buffer.add_string buffer value)
    fields;
  Digestif.SHA256.(to_hex (digest_string (Buffer.contents buffer)))
;;

let content_revision_of_source_text source_text =
  digest_fields [ "skill_document", source_text ]
;;

let content_revision_to_string revision = revision
let equal_content_revision = String.equal
let make_identity ~source_id ~package_id ~name = { source_id; package_id; name }
let make ~identity ~content_revision = { identity; content_revision }

let equal_identity left right =
  String.equal
    (Skill_source_config.source_id_to_string left.source_id)
    (Skill_source_config.source_id_to_string right.source_id)
  && String.equal left.package_id right.package_id
  && String.equal left.name right.name
;;

let equal left right =
  equal_identity left.identity right.identity
  && equal_content_revision left.content_revision right.content_revision
;;

(* The identity as one string a model can be given a closed choice of.

   Three parts, because two is not unique: one source publishes many packages
   and one package holds many Skills, so [source/name] can name two different
   documents. The content revision is deliberately absent -- the turn's frozen
   snapshot already fixes which revision this identity resolves to, and asking
   the model to echo 64 hex characters back is copying what the server
   already knows.

   Separator is [/] because the parts are already path-shaped and none of
   them may contain one: a package id with a separator is rejected at
   construction ([Package_id_contains_separator]). *)
let identity_key identity =
  String.concat "/"
    [ Skill_source_config.source_id_to_string identity.source_id
    ; (identity.package_id :> string)
    ; identity.name
    ]
;;

let key reference = identity_key reference.identity

let identity_to_yojson identity =
  `Assoc
    [ ( "source_id"
      , `String (Skill_source_config.source_id_to_string identity.source_id) )
    ; "package_id", `String identity.package_id
    ; "name", `String identity.name
    ]
;;

let to_yojson reference =
  `Assoc
    [ "identity", identity_to_yojson reference.identity
    ; "content_revision", `String reference.content_revision
    ]
;;

let pp formatter reference =
  Format.pp_print_string formatter (Yojson.Safe.to_string (to_yojson reference))
;;

let list_to_yojson references = `List (List.map to_yojson references)

let object_fields ~field = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Expected_object { field })
;;

let exact_fields ~object_name ~allowed fields =
  let rec inspect seen = function
    | [] -> Ok ()
    | (field, _) :: rest ->
      if List.mem field seen
      then Error (Duplicate_field { object_name; field })
      else if not (List.mem field allowed)
      then Error (Unexpected_field { object_name; field })
      else inspect (field :: seen) rest
  in
  inspect [] fields
;;

let required_value ~object_name ~field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Missing_field { object_name; field })
;;

let required_string ~object_name ~field fields =
  let* value = required_value ~object_name ~field fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Expected_string { object_name; field })
;;

let identity_of_yojson json =
  let object_name = "identity" in
  let* fields = object_fields ~field:object_name json in
  let* () =
    exact_fields
      ~object_name
      ~allowed:[ "source_id"; "package_id"; "name" ]
      fields
  in
  let* source = required_string ~object_name ~field:"source_id" fields in
  let* package = required_string ~object_name ~field:"package_id" fields in
  let* name = required_string ~object_name ~field:"name" fields in
  let* source_id =
    Skill_source_config.source_id_of_string source
    |> Result.map_error (fun _ -> Invalid_source_id source)
  in
  let* package_id =
    package_id_of_directory package
    |> Result.map_error (fun error -> Invalid_package_id error)
  in
  Ok (make_identity ~source_id ~package_id ~name)
;;

let of_yojson json =
  let object_name = "skill_reference" in
  let* fields = object_fields ~field:object_name json in
  let* () =
    exact_fields
      ~object_name
      ~allowed:[ "identity"; "content_revision" ]
      fields
  in
  let* identity_json = required_value ~object_name ~field:"identity" fields in
  let* identity = identity_of_yojson identity_json in
  let* content = required_string ~object_name ~field:"content_revision" fields in
  let* content_revision =
    content_revision_of_string content
    |> Result.map_error (fun error -> Invalid_content_revision error)
  in
  Ok (make ~identity ~content_revision)
;;

let list_of_yojson = function
  | `List values ->
    let rec decode decoded = function
      | [] -> Ok (List.rev decoded)
      | json :: rest ->
        let* reference = of_yojson json in
        (match List.find_opt (equal reference) decoded with
         | Some duplicate -> Error (Duplicate_reference duplicate)
         | None -> decode (reference :: decoded) rest)
    in
    decode [] values
  | _ -> Error (Expected_list { field = "skill_references" })
;;
