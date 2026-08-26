type standard_field =
  | Name
  | Description
  | License
  | Compatibility
  | Metadata
  | Allowed_tools

type field =
  | Standard of standard_field
  | Extension of string

type expected_shape =
  | String_value
  | String_mapping

type name_violation =
  | Empty_name
  | Name_too_long of
      { length : int
      ; maximum : int
      }
  | Name_not_lowercase
  | Name_starts_with_hyphen
  | Name_ends_with_hyphen
  | Name_has_consecutive_hyphens
  | Name_has_invalid_character

type diagnostic =
  | Missing_frontmatter
  | Unterminated_frontmatter
  | Malformed_yaml of string
  | Frontmatter_not_mapping
  | Duplicate_field of field
  | Duplicate_metadata_key of string
  | Unexpected_frontmatter_field of string
  | Missing_name
  | Missing_description
  | Invalid_field_type of
      { field : field
      ; expected : expected_shape
      }
  | Invalid_name of
      { name : string
      ; violations : name_violation list
      }
  | Name_mismatch of
      { declared : string
      ; directory : string
      }
  | Description_too_long of { length : int }
  | Compatibility_empty
  | Compatibility_too_long of { length : int }
  | Invalid_metadata_value of { key : string }

type conformance =
  | Conformant
  | Runtime_compatible of diagnostic list

type extension_value =
  | Null
  | Boolean of bool
  | Number of float
  | Text of string
  | Sequence of extension_value list
  | Mapping of (string * extension_value) list

type t =
  { name : string
  ; declared_name : string option
  ; description : string
  ; license : string option
  ; compatibility : string option
  ; metadata : (string * string) list
  ; metadata_values : (string * extension_value) list
  ; allowed_tools : string option
  ; extensions : (string * extension_value) list
  ; body : string
  }

type load_outcome =
  | Loaded of
      { document : t
      ; conformance : conformance
      }
  | Unloadable of diagnostic list

type line =
  { start : int
  ; next : int
  ; text : string
  }

let line_at contents start =
  let length = String.length contents in
  if start >= length
  then None
  else
    let stop =
      match String.index_from_opt contents start '\n' with
      | Some index -> index
      | None -> length
    in
    let raw = String.sub contents start (stop - start) in
    let raw_length = String.length raw in
    let text =
      if raw_length > 0 && Char.equal raw.[raw_length - 1] '\r'
      then String.sub raw 0 (raw_length - 1)
      else raw
    in
    let next = if stop < length then stop + 1 else length in
    Some { start; next; text }
;;

let split_frontmatter contents =
  match line_at contents 0 with
  | None | Some { text = ""; _ } -> Error Missing_frontmatter
  | Some first when not (String.equal first.text "---") -> Error Missing_frontmatter
  | Some first ->
    let rec find_close position =
      match line_at contents position with
      | None -> Error Unterminated_frontmatter
      | Some line when String.equal line.text "---" ->
        let yaml = String.sub contents first.next (line.start - first.next) in
        let body =
          String.sub contents line.next (String.length contents - line.next)
        in
        Ok (yaml, body)
      | Some line -> find_close line.next
    in
    find_close first.next
;;

module Spec_limits = struct
  let name = 64
  let description = 1024
  let compatibility = 500
end

let standard_field_of_key = function
  | "name" -> Some Name
  | "description" -> Some Description
  | "license" -> Some License
  | "compatibility" -> Some Compatibility
  | "metadata" -> Some Metadata
  | "allowed-tools" -> Some Allowed_tools
  | _ -> None
;;

let field_of_key key =
  match standard_field_of_key key with
  | Some field -> Standard field
  | None -> Extension key
;;

let duplicate_fields fields =
  let rec loop seen duplicates = function
    | [] -> List.rev duplicates
    | (key, _) :: rest ->
      if List.mem key seen
      then loop seen (Duplicate_field (field_of_key key) :: duplicates) rest
      else loop (key :: seen) duplicates rest
  in
  loop [] [] fields
;;

let field fields key = List.assoc_opt key fields

let optional_string fields standard_field key =
  match field fields key with
  | None -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ ->
    Error
      (Invalid_field_type
         { field = Standard standard_field; expected = String_value })
;;

let required_description fields =
  match field fields "description" with
  | None | Some `Null -> Error Missing_description
  | Some (`String value) when String.equal (String.trim value) "" ->
    Error Missing_description
  | Some (`String value) -> Ok value
  | Some _ ->
    Error
      (Invalid_field_type
         { field = Standard Description; expected = String_value })
;;

let declared_name fields =
  match field fields "name" with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.equal (String.trim value) "" -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ ->
    Error (Invalid_field_type { field = Standard Name; expected = String_value })
;;

let utf_8_scalar_length value =
  let rec loop index count =
    if index = String.length value
    then Some count
    else
      let decoded = String.get_utf_8_uchar value index in
      if not (Uchar.utf_decode_is_valid decoded)
      then None
      else loop (index + Uchar.utf_decode_length decoded) (count + 1)
  in
  loop 0 0
;;

let lowercase_utf_8 value =
  let buffer = Buffer.create (String.length value) in
  let rec loop index =
    if index = String.length value
    then Some (Buffer.contents buffer)
    else
      let decoded = String.get_utf_8_uchar value index in
      if not (Uchar.utf_decode_is_valid decoded)
      then None
      else (
        let scalar = Uchar.utf_decode_uchar decoded in
        (match Uucp.Case.Map.to_lower scalar with
         | `Self -> Buffer.add_utf_8_uchar buffer scalar
         | `Uchars scalars -> List.iter (Buffer.add_utf_8_uchar buffer) scalars);
        loop (index + Uchar.utf_decode_length decoded))
  in
  loop 0
;;

let name_has_invalid_character name =
  let hyphen = Uchar.of_char '-' in
  let rec loop index =
    if index = String.length name
    then false
    else
      let decoded = String.get_utf_8_uchar name index in
      if not (Uchar.utf_decode_is_valid decoded)
      then true
      else
        let scalar = Uchar.utf_decode_uchar decoded in
        if
          Uchar.equal scalar hyphen
          || Uucp.Alpha.is_alphabetic scalar
          || not (Uucp.Num.numeric_type scalar = `None)
        then loop (index + Uchar.utf_decode_length decoded)
        else true
  in
  loop 0
;;

let name_has_consecutive_hyphens name =
  let rec loop index =
    index + 1 < String.length name
    &&
    if Char.equal name.[index] '-' && Char.equal name.[index + 1] '-'
    then true
    else loop (index + 1)
  in
  loop 0
;;

let analyze_name name =
  let normalized = Uunf_string.normalize_utf_8 `NFKC (String.trim name) in
  let scalar_length = utf_8_scalar_length normalized in
  let byte_length = String.length normalized in
  let add_if condition violation violations =
    if condition then violation :: violations else violations
  in
  let violations = [] in
  let violations = add_if (byte_length = 0) Empty_name violations in
  let violations =
    match scalar_length with
    | Some length when length > Spec_limits.name ->
      Name_too_long { length; maximum = Spec_limits.name } :: violations
    | Some _ | None -> violations
  in
  let violations =
    add_if
      (byte_length > 0 && Char.equal normalized.[0] '-')
      Name_starts_with_hyphen
      violations
  in
  let violations =
    add_if
      (byte_length > 0 && Char.equal normalized.[byte_length - 1] '-')
      Name_ends_with_hyphen
      violations
  in
  let violations =
    add_if
      (name_has_consecutive_hyphens normalized)
      Name_has_consecutive_hyphens
      violations
  in
  let violations =
    add_if
      (name_has_invalid_character normalized)
      Name_has_invalid_character
      violations
  in
  let violations =
    match lowercase_utf_8 normalized with
    | Some lowercase when not (String.equal normalized lowercase) ->
      Name_not_lowercase :: violations
    | Some _ | None -> violations
  in
  normalized, List.rev violations
;;

let canonical_name name =
  match analyze_name name with
  | canonical, [] -> Ok canonical
  | _, violations -> Error violations
;;

let rec extension_value_of_yaml = function
  | `Null -> Null
  | `Bool value -> Boolean value
  | `Float value -> Number value
  | `String value -> Text value
  | `A values -> Sequence (List.map extension_value_of_yaml values)
  | `O fields ->
    Mapping
      (List.map
         (fun (key, value) -> key, extension_value_of_yaml value)
         fields)
;;

let duplicate_keys fields =
  let rec loop seen duplicates = function
    | [] -> List.rev duplicates
    | (key, _) :: rest ->
      if List.mem key seen
      then
        let duplicates = if List.mem key duplicates then duplicates else key :: duplicates in
        loop seen duplicates rest
      else loop (key :: seen) duplicates rest
  in
  loop [] [] fields
;;

let metadata fields =
  match field fields "metadata" with
  | None -> [], [], []
  | Some (`O pairs) ->
    let duplicates = duplicate_keys pairs in
    let values =
      List.map
        (fun (key, value) -> key, extension_value_of_yaml value)
        pairs
    in
    let valid, value_diagnostics =
      List.fold_left
        (fun (valid, diagnostics) (key, value) ->
           match value with
           | `String value when not (List.mem key duplicates) ->
             (key, value) :: valid, diagnostics
           | `String _ -> valid, diagnostics
           | _ -> valid, Invalid_metadata_value { key } :: diagnostics)
        ([], [])
        pairs
    in
    ( List.rev valid
    , values
    , List.map (fun key -> Duplicate_metadata_key key) duplicates
      @ List.rev value_diagnostics )
  | Some _ ->
    ( []
    , []
    , [ Invalid_field_type
          { field = Standard Metadata; expected = String_mapping }
      ] )
;;

let extensions fields =
  List.filter_map
    (fun (key, value) ->
       match standard_field_of_key key with
       | Some _ -> None
       | None -> Some (key, extension_value_of_yaml value))
    fields
;;

let runtime_name ~directory_name declared =
  let directory, directory_violations = analyze_name directory_name in
  let invalid_name name violations = Invalid_name { name; violations } in
  match declared with
  | Some declared_name ->
    let declared, declared_violations = analyze_name declared_name in
    (match declared_violations, directory_violations with
     | [], [] when String.equal declared directory -> Ok (declared, [])
     | [], [] ->
       Ok
         ( directory
         , [ Name_mismatch
               { declared = declared_name; directory = directory_name }
           ] )
     | [], directory_violations ->
       Ok
         ( declared
         , [ Name_mismatch
               { declared = declared_name; directory = directory_name }
           ; invalid_name directory_name directory_violations
           ] )
     | declared_violations, [] ->
       Ok (directory, [ invalid_name declared_name declared_violations ])
     | declared_violations, directory_violations ->
       Error
         [ invalid_name declared_name declared_violations
         ; invalid_name directory_name directory_violations
         ])
  | None ->
    (match directory_violations with
     | [] -> Ok (directory, [ Missing_name ])
     | violations -> Error [ Missing_name; invalid_name directory_name violations ])
;;

let decode ~directory_name contents =
  match split_frontmatter contents with
  | Error diagnostic -> Unloadable [ diagnostic ]
  | Ok (yaml, body) ->
    (match Yaml.of_string yaml with
     | Error (`Msg detail) -> Unloadable [ Malformed_yaml detail ]
     | Ok (`O fields) ->
       let duplicates = duplicate_fields fields in
       if duplicates <> []
       then Unloadable duplicates
       else
         (match declared_name fields, required_description fields with
          | Error diagnostic, _ | _, Error diagnostic ->
            Unloadable [ diagnostic ]
          | Ok declared_name, Ok description ->
            (match runtime_name ~directory_name declared_name with
             | Error diagnostics -> Unloadable diagnostics
             | Ok (name, name_diagnostics) ->
               let license, license_diagnostics =
                 match optional_string fields License "license" with
                 | Ok value -> value, []
                 | Error diagnostic -> None, [ diagnostic ]
               in
               let compatibility, compatibility_diagnostics =
                 match optional_string fields Compatibility "compatibility" with
                 | Ok value -> value, []
                 | Error diagnostic -> None, [ diagnostic ]
               in
               let allowed_tools, allowed_tools_diagnostics =
                 match optional_string fields Allowed_tools "allowed-tools" with
                 | Ok value -> value, []
                 | Error diagnostic -> None, [ diagnostic ]
               in
               let metadata, metadata_values, metadata_diagnostics = metadata fields in
               let extension_values = extensions fields in
               let extension_diagnostics =
                 List.map
                   (fun (key, _) -> Unexpected_frontmatter_field key)
                   extension_values
               in
               let length_diagnostics =
                 (match utf_8_scalar_length description with
                  | Some length when length > Spec_limits.description ->
                    [ Description_too_long { length } ]
                  | Some _ | None -> [])
                 @
                 match compatibility with
                 | Some value when String.equal value "" -> [ Compatibility_empty ]
                 | Some value ->
                   (match utf_8_scalar_length value with
                    | Some length when length > Spec_limits.compatibility ->
                      [ Compatibility_too_long { length } ]
                    | Some _ | None -> [])
                 | None -> []
               in
               let diagnostics =
                 name_diagnostics
                 @ license_diagnostics
                 @ compatibility_diagnostics
                 @ allowed_tools_diagnostics
                 @ metadata_diagnostics
                 @ extension_diagnostics
                 @ length_diagnostics
               in
               let document =
                 { name
                 ; declared_name
                 ; description
                 ; license
                 ; compatibility
                 ; metadata
                 ; metadata_values
                 ; allowed_tools
                 ; extensions = extension_values
                 ; body
                 }
               in
               Loaded
                 { document
                 ; conformance =
                     (match diagnostics with
                      | [] -> Conformant
                      | diagnostics -> Runtime_compatible diagnostics)
                 }))
     | Ok _ -> Unloadable [ Frontmatter_not_mapping ])
;;

let diagnostics = function
  | Loaded { conformance = Conformant; _ } -> []
  | Loaded { conformance = Runtime_compatible diagnostics; _ }
  | Unloadable diagnostics -> diagnostics
;;

let standard_field_to_string = function
  | Name -> "name"
  | Description -> "description"
  | License -> "license"
  | Compatibility -> "compatibility"
  | Metadata -> "metadata"
  | Allowed_tools -> "allowed-tools"
;;

let field_to_string = function
  | Standard field -> standard_field_to_string field
  | Extension key -> key
;;

let expected_shape_to_string = function
  | String_value -> "a string"
  | String_mapping -> "a mapping of string values"
;;

let name_violation_to_string = function
  | Empty_name -> "is empty"
  | Name_too_long { length; maximum } ->
    Printf.sprintf "has %d characters; maximum is %d" length maximum
  | Name_not_lowercase -> "is not lowercase"
  | Name_starts_with_hyphen -> "starts with a hyphen"
  | Name_ends_with_hyphen -> "ends with a hyphen"
  | Name_has_consecutive_hyphens -> "contains consecutive hyphens"
  | Name_has_invalid_character ->
    "contains a character that is not a Unicode letter, number, or hyphen"
;;

let diagnostic_to_string = function
  | Missing_frontmatter -> "SKILL.md must start with YAML frontmatter"
  | Unterminated_frontmatter -> "SKILL.md frontmatter has no closing delimiter"
  | Malformed_yaml detail -> "SKILL.md frontmatter is invalid YAML: " ^ detail
  | Frontmatter_not_mapping -> "SKILL.md frontmatter must be a YAML mapping"
  | Duplicate_field field ->
    Printf.sprintf "SKILL.md frontmatter duplicates %S" (field_to_string field)
  | Duplicate_metadata_key key ->
    Printf.sprintf "SKILL.md metadata duplicates %S" key
  | Unexpected_frontmatter_field field ->
    Printf.sprintf "SKILL.md frontmatter field %S is not in the specification" field
  | Missing_name -> "SKILL.md frontmatter is missing required field name"
  | Missing_description ->
    "SKILL.md frontmatter is missing required non-empty field description"
  | Invalid_field_type { field; expected } ->
    Printf.sprintf
      "SKILL.md frontmatter field %S must be %s"
      (field_to_string field)
      (expected_shape_to_string expected)
  | Invalid_name { name; violations } ->
    Printf.sprintf
      "SKILL.md name %S %s"
      name
      (violations
       |> List.map name_violation_to_string
       |> String.concat "; ")
  | Name_mismatch { declared; directory } ->
    Printf.sprintf "SKILL.md name %S does not match directory %S" declared directory
  | Description_too_long { length } ->
    Printf.sprintf
      "SKILL.md description has %d characters; maximum is %d"
      length
      Spec_limits.description
  | Compatibility_empty -> "SKILL.md compatibility must not be empty"
  | Compatibility_too_long { length } ->
    Printf.sprintf
      "SKILL.md compatibility has %d characters; maximum is %d"
      length
      Spec_limits.compatibility
  | Invalid_metadata_value { key } ->
    Printf.sprintf "SKILL.md metadata value for %S must be a string" key
;;

let conformance_to_string = function
  | Conformant -> "conformant"
  | Runtime_compatible _ -> "runtime_compatible"
;;
