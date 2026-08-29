type source_id = string

type anchor =
  | Base_path
  | User_home
  | Absolute

type access =
  | Read_only
  | Read_write

type resource_read_max_bytes = int

type source =
  { id : source_id
  ; anchor : anchor
  ; configured_path : string
  ; access : access
  }

type t =
  { resource_read_max_bytes : resource_read_max_bytes option
  ; sources : source list
  }

type source_field =
  | Id
  | Anchor
  | Path
  | Access
  | Unexpected of string

type value_kind =
  | String
  | Integer
  | Float
  | Boolean
  | Array
  | Table
  | Table_array
  | Date_time

type path_rejection =
  | Contains_nul
  | Expected_relative
  | Expected_absolute
  | Empty_component
  | Current_directory_component
  | Parent_directory_component

type anchor_rejection =
  | Empty_anchor
  | Relative_anchor
  | Anchor_contains_nul

type diagnostic =
  | Toml_syntax of string
  | Missing_resource_read_max_bytes
  | Invalid_resource_read_max_bytes_type of value_kind
  | Non_positive_resource_read_max_bytes of int
  | Unexpected_skill_field of string
  | Invalid_sources_type of value_kind
  | Invalid_source_entry_type of
      { index : int
      ; actual : value_kind
      }
  | Missing_source_field of
      { index : int
      ; field : source_field
      }
  | Invalid_source_field_type of
      { index : int
      ; field : source_field
      ; actual : value_kind
      }
  | Unexpected_source_field of
      { index : int
      ; field : string
      }
  | Invalid_source_id of
      { index : int
      ; value : string
      }
  | Unsupported_anchor of
      { index : int
      ; value : string
      }
  | Unsupported_access of
      { index : int
      ; value : string
      }
  | Invalid_source_path of
      { index : int
      ; rejection : path_rejection
      }
  | Duplicate_source_id of
      { first_index : int
      ; duplicate_index : int
      ; id : source_id
      }

type resolution =
  | Resolved of string
  | Anchor_unavailable of anchor
  | Anchor_invalid of
      { anchor : anchor
      ; rejection : anchor_rejection
      }
  | Path_rejected of path_rejection

type resolved_source =
  { source : source
  ; resolution : resolution
  }

let source_id_to_string id = id
let resource_read_max_bytes_to_int value = value

let source_id_of_string id =
  if Safe_identifier.is_portable_name id
  then Ok id
  else Error (Printf.sprintf "invalid Skill source id %S" id)
;;

let top_level_namespace = "skills"

let anchor_to_string = function
  | Base_path -> "base-path"
  | User_home -> "user-home"
  | Absolute -> "absolute"
;;

let access_to_string = function
  | Read_only -> "read-only"
  | Read_write -> "read-write"
;;

let value_kind = function
  | Keeper_toml_loader.Toml_string _ -> String
  | Toml_int _ -> Integer
  | Toml_float _ -> Float
  | Toml_bool _ -> Boolean
  | Toml_string_array _ | Toml_array _ -> Array
  | Toml_table _ | Toml_inline_table _ -> Table
  | Toml_table_array _ -> Table_array
  | Toml_offset_datetime _ | Toml_local_datetime _ | Toml_local_date _
  | Toml_local_time _ -> Date_time
;;

let value_kind_to_string = function
  | String -> "string"
  | Integer -> "integer"
  | Float -> "float"
  | Boolean -> "boolean"
  | Array -> "array"
  | Table -> "table"
  | Table_array -> "table array"
  | Date_time -> "date/time"
;;

let source_field_to_string = function
  | Id -> "id"
  | Anchor -> "anchor"
  | Path -> "path"
  | Access -> "access"
  | Unexpected field -> field
;;

let path_rejection_to_string = function
  | Contains_nul -> "contains a NUL byte"
  | Expected_relative -> "must be relative to its anchor"
  | Expected_absolute -> "must be absolute for the absolute anchor"
  | Empty_component -> "contains an empty path component"
  | Current_directory_component -> "contains a current-directory component"
  | Parent_directory_component -> "contains a parent-directory component"
;;

let anchor_rejection_to_string = function
  | Empty_anchor -> "anchor is empty"
  | Relative_anchor -> "anchor must be absolute"
  | Anchor_contains_nul -> "anchor contains a NUL byte"
;;

let diagnostic_to_string = function
  | Toml_syntax detail -> "invalid runtime TOML: " ^ detail
  | Missing_resource_read_max_bytes ->
    "skills.resource-read-max-bytes is required"
  | Invalid_resource_read_max_bytes_type actual ->
    Printf.sprintf
      "skills.resource-read-max-bytes must be an integer, got %s"
      (value_kind_to_string actual)
  | Non_positive_resource_read_max_bytes value ->
    Printf.sprintf
      "skills.resource-read-max-bytes must be positive, got %d"
      value
  | Unexpected_skill_field field ->
    Printf.sprintf "skills has unexpected field %S" field
  | Invalid_sources_type actual ->
    Printf.sprintf
      "skills.sources must be an array of tables, got %s"
      (value_kind_to_string actual)
  | Invalid_source_entry_type { index; actual } ->
    Printf.sprintf
      "skills.sources[%d] must be a table, got %s"
      index
      (value_kind_to_string actual)
  | Missing_source_field { index; field } ->
    Printf.sprintf
      "skills.sources[%d] is missing %s"
      index
      (source_field_to_string field)
  | Invalid_source_field_type { index; field; actual } ->
    Printf.sprintf
      "skills.sources[%d].%s must be a string, got %s"
      index
      (source_field_to_string field)
      (value_kind_to_string actual)
  | Unexpected_source_field { index; field } ->
    Printf.sprintf "skills.sources[%d] has unexpected field %S" index field
  | Invalid_source_id { index; value } ->
    Printf.sprintf "skills.sources[%d].id is not a portable identifier: %S" index value
  | Unsupported_anchor { index; value } ->
    Printf.sprintf "skills.sources[%d].anchor is unsupported: %S" index value
  | Unsupported_access { index; value } ->
    Printf.sprintf "skills.sources[%d].access is unsupported: %S" index value
  | Invalid_source_path { index; rejection } ->
    Printf.sprintf
      "skills.sources[%d].path %s"
      index
      (path_rejection_to_string rejection)
  | Duplicate_source_id { first_index; duplicate_index; id } ->
    Printf.sprintf
      "skills.sources[%d].id duplicates skills.sources[%d].id %S"
      duplicate_index
      first_index
      id
;;

let field_of_name = function
  | "id" -> Some Id
  | "anchor" -> Some Anchor
  | "path" -> Some Path
  | "access" -> Some Access
  | _ -> None
;;

let string_field ~index ~field fields =
  let key = source_field_to_string field in
  match List.assoc_opt key fields with
  | None -> Error (Missing_source_field { index; field })
  | Some (Keeper_toml_loader.Toml_string value) -> Ok value
  | Some value ->
    Error (Invalid_source_field_type { index; field; actual = value_kind value })
;;

let anchor_of_string ~index = function
  | "base-path" -> Ok Base_path
  | "user-home" -> Ok User_home
  | "absolute" -> Ok Absolute
  | value -> Error (Unsupported_anchor { index; value })
;;

let access_of_string ~index = function
  | "read-only" -> Ok Read_only
  | "read-write" -> Ok Read_write
  | value -> Error (Unsupported_access { index; value })
;;

let relative_path_rejection path =
  if String.contains path '\000'
  then Some Contains_nul
  else if not (Filename.is_relative path)
  then Some Expected_relative
  else
    let rec inspect = function
      | [] -> None
      | "" :: _ -> Some Empty_component
      | "." :: _ -> Some Current_directory_component
      | ".." :: _ -> Some Parent_directory_component
      | _ :: rest -> inspect rest
    in
    inspect (String.split_on_char '/' path)
;;

let absolute_path_rejection path =
  if String.contains path '\000'
  then Some Contains_nul
  else if Filename.is_relative path
  then Some Expected_absolute
  else None
;;

let path_rejection anchor path =
  match anchor with
  | Base_path | User_home -> relative_path_rejection path
  | Absolute -> absolute_path_rejection path
;;

let collect_results results =
  List.fold_right
    (fun result (values, diagnostics) ->
       match result with
       | Ok value -> value :: values, diagnostics
       | Error diagnostic -> values, diagnostic :: diagnostics)
    results
    ([], [])
;;

let parse_source ~index fields =
  let unexpected =
    List.filter_map
      (fun (key, _) ->
         match field_of_name key with
         | Some _ -> None
         | None -> Some (Unexpected_source_field { index; field = key }))
      fields
  in
  let id = string_field ~index ~field:Id fields in
  let anchor = string_field ~index ~field:Anchor fields in
  let configured_path = string_field ~index ~field:Path fields in
  let access = string_field ~index ~field:Access fields in
  let values, field_diagnostics = collect_results [ id; anchor; configured_path; access ] in
  match values, unexpected @ field_diagnostics with
  | [ id; anchor; configured_path; access ], [] ->
    let id =
      if Safe_identifier.is_portable_name id
      then Ok id
      else Error (Invalid_source_id { index; value = id })
    in
    let anchor = anchor_of_string ~index anchor in
    let access = access_of_string ~index access in
    (match id, anchor, access with
     | Ok id, Ok anchor, Ok access ->
       (match path_rejection anchor configured_path with
        | None -> Ok { id; anchor; configured_path; access }
        | Some rejection -> Error [ Invalid_source_path { index; rejection } ])
     | _ ->
       let diagnostics =
         [ (match id with
            | Error diagnostic -> Some diagnostic
            | Ok _ -> None)
         ; (match anchor with
            | Error diagnostic -> Some diagnostic
            | Ok _ -> None)
         ; (match access with
            | Error diagnostic -> Some diagnostic
            | Ok _ -> None)
         ]
         |> List.filter_map Fun.id
       in
       Error diagnostics)
  | _, diagnostics -> Error diagnostics
;;

let parse_entry ~index = function
  | Keeper_toml_loader.Toml_table fields
  | Toml_inline_table fields -> parse_source ~index fields
  | value -> Error [ Invalid_source_entry_type { index; actual = value_kind value } ]
;;

let resource_read_max_bytes_key = top_level_namespace ^ ".resource-read-max-bytes"
let sources_key = top_level_namespace ^ ".sources"

let resource_read_max_bytes ~required doc =
  match List.assoc_opt resource_read_max_bytes_key doc with
  | None ->
    if required then None, [ Missing_resource_read_max_bytes ] else None, []
  | Some (Keeper_toml_loader.Toml_int value) when value > 0 -> Some value, []
  | Some (Toml_int value) -> None, [ Non_positive_resource_read_max_bytes value ]
  | Some value ->
    None, [ Invalid_resource_read_max_bytes_type (value_kind value) ]
;;

let source_entries doc =
  match List.assoc_opt sources_key doc with
  | None -> Ok []
  | Some (Keeper_toml_loader.Toml_table_array entries) -> Ok entries
  | Some value -> Error (Invalid_sources_type (value_kind value))
;;

let duplicate_diagnostics indexed_sources =
  let seen = Hashtbl.create (List.length indexed_sources) in
  indexed_sources
  |> List.filter_map (fun (index, source) ->
    match Hashtbl.find_opt seen source.id with
    | None ->
      Hashtbl.add seen source.id index;
      None
    | Some first_index ->
      Some
        (Duplicate_source_id
           { first_index; duplicate_index = index; id = source.id }))
;;

let parse_doc doc =
  let namespace_prefix = top_level_namespace ^ "." in
  let known_fields =
    [ resource_read_max_bytes_key
    ; sources_key
    ]
  in
  let configured =
    List.exists (fun (key, _) -> String.starts_with ~prefix:namespace_prefix key) doc
  in
  let unexpected =
    List.filter_map
      (fun (key, _) ->
         if
           String.starts_with ~prefix:namespace_prefix key
           && not (List.mem key known_fields)
         then
           Some
             (Unexpected_skill_field
                (String.sub
                   key
                   (String.length namespace_prefix)
                   (String.length key - String.length namespace_prefix)))
         else None)
      doc
  in
  let resource_read_max_bytes, resource_read_max_bytes_diagnostics =
    resource_read_max_bytes ~required:configured doc
  in
  let entries, source_container_diagnostics =
    match source_entries doc with
    | Ok entries -> entries, []
    | Error diagnostic -> [], [ diagnostic ]
  in
  let parsed_entries =
    List.mapi (fun index entry -> index, parse_entry ~index entry) entries
  in
  let indexed_sources, entry_diagnostics =
    List.fold_right
      (fun (index, result) (sources, diagnostics) ->
         match result with
         | Ok source -> (index, source) :: sources, diagnostics
         | Error errors -> sources, errors @ diagnostics)
      parsed_entries
      ([], [])
  in
  let diagnostics =
    unexpected
    @ resource_read_max_bytes_diagnostics
    @ source_container_diagnostics
    @ entry_diagnostics
    @ duplicate_diagnostics indexed_sources
  in
  if diagnostics = []
  then
    Ok
      { resource_read_max_bytes
      ; sources = List.map snd indexed_sources
      }
  else Error diagnostics
;;

let parse_text content =
  match Keeper_toml_loader.parse_toml content with
  | Ok doc -> parse_doc doc
  | Error detail -> Error [ Toml_syntax detail ]
;;

let validate_text content = Result.map (fun _ -> ()) (parse_text content)

let to_yojson config =
  `Assoc
    [ ( "resource_read_max_bytes"
      , match config.resource_read_max_bytes with
        | Some value -> `Int (resource_read_max_bytes_to_int value)
        | None -> `Null )
    ; ( "sources"
      , `List
          (List.map
             (fun source ->
                `Assoc
                  [ "id", `String (source_id_to_string source.id)
                  ; "anchor", `String (anchor_to_string source.anchor)
                  ; "path", `String source.configured_path
                  ; "access", `String (access_to_string source.access)
                  ])
             config.sources) )
    ]
;;

let normalize_absolute path =
  let components = String.split_on_char '/' path in
  let normalized =
    List.fold_left
      (fun stack component ->
         match component, stack with
         | ("" | "."), _ -> stack
         | "..", _ :: rest -> rest
         | "..", [] -> []
         | component, _ -> component :: stack)
      []
      components
    |> List.rev
  in
  "/" ^ String.concat "/" normalized
;;

let anchor_rejection path =
  if String.equal path ""
  then Some Empty_anchor
  else if String.contains path '\000'
  then Some Anchor_contains_nul
  else if Filename.is_relative path
  then Some Relative_anchor
  else None
;;

let resolve ~base_path ~user_home source =
  let resolution =
    match path_rejection source.anchor source.configured_path with
    | Some rejection -> Path_rejected rejection
    | None ->
      (match source.anchor with
       | Base_path ->
         (match anchor_rejection base_path with
          | Some rejection -> Anchor_invalid { anchor = Base_path; rejection }
          | None -> Resolved (Filename.concat base_path source.configured_path))
       | User_home ->
         (match user_home with
          | Some home ->
            (match anchor_rejection home with
             | Some rejection -> Anchor_invalid { anchor = User_home; rejection }
             | None -> Resolved (Filename.concat home source.configured_path))
          | None -> Anchor_unavailable User_home)
       | Absolute -> Resolved (normalize_absolute source.configured_path))
  in
  { source; resolution }
;;
