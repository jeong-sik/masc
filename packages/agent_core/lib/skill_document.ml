type diagnostic =
  | Missing_frontmatter
  | Unterminated_frontmatter
  | Malformed_yaml of string
  | Frontmatter_not_mapping
  | Duplicate_field of string
  | Missing_name
  | Missing_description
  | Invalid_field_type of
      { field : string
      ; expected : string
      }
  | Invalid_name of string
  | Name_mismatch of
      { declared : string
      ; directory : string
      }
  | Description_too_long of { length : int }
  | Compatibility_too_long of { length : int }
  | Invalid_metadata_value of { key : string }

type conformance =
  | Conformant
  | Runtime_compatible of diagnostic list

type t =
  { name : string
  ; declared_name : string option
  ; description : string
  ; license : string option
  ; compatibility : string option
  ; metadata : (string * string) list
  ; allowed_tools : string option
  ; extensions : (string * Yaml.value) list
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

let standard_fields =
  [ "name"; "description"; "license"; "compatibility"; "metadata"; "allowed-tools" ]
;;

let duplicate_fields fields =
  let rec loop seen duplicates = function
    | [] -> List.rev duplicates
    | (key, _) :: rest ->
      if List.mem key seen
      then loop seen (Duplicate_field key :: duplicates) rest
      else loop (key :: seen) duplicates rest
  in
  loop [] [] fields
;;

let field fields key = List.assoc_opt key fields

let optional_string fields key =
  match field fields key with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (Invalid_field_type { field = key; expected = "string" })
;;

let required_description fields =
  match field fields "description" with
  | None | Some `Null -> Error Missing_description
  | Some (`String value) when String.equal (String.trim value) "" ->
    Error Missing_description
  | Some (`String value) -> Ok value
  | Some _ ->
    Error (Invalid_field_type { field = "description"; expected = "string" })
;;

let declared_name fields =
  match field fields "name" with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.equal (String.trim value) "" -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (Invalid_field_type { field = "name"; expected = "string" })
;;

let valid_name name =
  let length = String.length name in
  let valid_character = function
    | 'a' .. 'z' | '0' .. '9' | '-' -> true
    | _ -> false
  in
  let rec characters index previous_hyphen =
    if index = length
    then true
    else
      let character = name.[index] in
      if not (valid_character character)
      then false
      else
        let hyphen = Char.equal character '-' in
        if hyphen && previous_hyphen
        then false
        else characters (index + 1) hyphen
  in
  length >= 1
  && length <= 64
  && not (Char.equal name.[0] '-')
  && not (Char.equal name.[length - 1] '-')
  && characters 0 false
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

let metadata fields =
  match field fields "metadata" with
  | None | Some `Null -> [], []
  | Some (`O pairs) ->
    List.fold_left
      (fun (valid, diagnostics) (key, value) ->
         match value with
         | `String value -> (key, value) :: valid, diagnostics
         | _ -> valid, Invalid_metadata_value { key } :: diagnostics)
      ([], [])
      pairs
    |> fun (valid, diagnostics) -> List.rev valid, List.rev diagnostics
  | Some _ ->
    ( []
    , [ Invalid_field_type
          { field = "metadata"; expected = "mapping of string values" }
      ] )
;;

let extensions fields =
  List.filter (fun (key, _) -> not (List.mem key standard_fields)) fields
;;

let runtime_name ~directory_name declared =
  match declared with
  | Some name when valid_name name && String.equal name directory_name -> Ok (name, [])
  | Some name when valid_name name && valid_name directory_name ->
    Ok
      ( directory_name
      , [ Name_mismatch { declared = name; directory = directory_name } ] )
  | Some name when valid_name name ->
    let diagnostics =
      [ Name_mismatch { declared = name; directory = directory_name }
      ; Invalid_name directory_name
      ]
    in
    Ok (name, diagnostics)
  | Some declared when valid_name directory_name ->
    Ok (directory_name, [ Invalid_name declared ])
  | Some declared -> Error [ Invalid_name declared ]
  | None when valid_name directory_name -> Ok (directory_name, [ Missing_name ])
  | None -> Error [ Missing_name; Invalid_name directory_name ]
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
                 match optional_string fields "license" with
                 | Ok value -> value, []
                 | Error diagnostic -> None, [ diagnostic ]
               in
               let compatibility, compatibility_diagnostics =
                 match optional_string fields "compatibility" with
                 | Ok value -> value, []
                 | Error diagnostic -> None, [ diagnostic ]
               in
               let allowed_tools, allowed_tools_diagnostics =
                 match optional_string fields "allowed-tools" with
                 | Ok value -> value, []
                 | Error diagnostic -> None, [ diagnostic ]
               in
               let metadata, metadata_diagnostics = metadata fields in
               let length_diagnostics =
                 (match utf_8_scalar_length description with
                  | Some length when length > 1024 ->
                    [ Description_too_long { length } ]
                  | Some _ | None -> [])
                 @
                 match compatibility with
                 | Some value ->
                   (match utf_8_scalar_length value with
                    | Some length when length > 500 ->
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
                 @ length_diagnostics
               in
               let document =
                 { name
                 ; declared_name
                 ; description
                 ; license
                 ; compatibility
                 ; metadata
                 ; allowed_tools
                 ; extensions = extensions fields
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

let diagnostic_to_string = function
  | Missing_frontmatter -> "SKILL.md must start with YAML frontmatter"
  | Unterminated_frontmatter -> "SKILL.md frontmatter has no closing delimiter"
  | Malformed_yaml detail -> "SKILL.md frontmatter is invalid YAML: " ^ detail
  | Frontmatter_not_mapping -> "SKILL.md frontmatter must be a YAML mapping"
  | Duplicate_field field -> Printf.sprintf "SKILL.md frontmatter duplicates %S" field
  | Missing_name -> "SKILL.md frontmatter is missing required field name"
  | Missing_description ->
    "SKILL.md frontmatter is missing required non-empty field description"
  | Invalid_field_type { field; expected } ->
    Printf.sprintf "SKILL.md frontmatter field %S must be %s" field expected
  | Invalid_name name -> Printf.sprintf "SKILL.md name %S violates the specification" name
  | Name_mismatch { declared; directory } ->
    Printf.sprintf "SKILL.md name %S does not match directory %S" declared directory
  | Description_too_long { length } ->
    Printf.sprintf "SKILL.md description has %d characters; maximum is 1024" length
  | Compatibility_too_long { length } ->
    Printf.sprintf "SKILL.md compatibility has %d characters; maximum is 500" length
  | Invalid_metadata_value { key } ->
    Printf.sprintf "SKILL.md metadata value for %S must be a string" key
;;

let conformance_to_string = function
  | Conformant -> "conformant"
  | Runtime_compatible _ -> "runtime_compatible"
;;
