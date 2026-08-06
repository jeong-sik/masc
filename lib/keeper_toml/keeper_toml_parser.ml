(** Keeper TOML semantic parsing backed by Otoml.

    Keeper consumers use a flat, canonical key-path projection. Semantic TOML
    parsing, escaping, quoted/dotted key handling, and value validation remain
    owned by Otoml; comment-preserving mutation remains in
    [Keeper_toml_loader]. *)

type toml_value =
  | Toml_string of string
  | Toml_int of int
  | Toml_float of float
  | Toml_bool of bool
  | Toml_string_array of string list
  | Toml_array of toml_value list
  | Toml_table of (string * toml_value) list
  | Toml_inline_table of (string * toml_value) list
  | Toml_table_array of toml_value list
  | Toml_offset_datetime of string
  | Toml_local_datetime of string
  | Toml_local_date of string
  | Toml_local_time of string

type toml_doc = (string * toml_value) list

let rec toml_value_of_otoml = function
  | Otoml.TomlString value -> Toml_string value
  | Otoml.TomlInteger value -> Toml_int value
  | Otoml.TomlFloat value -> Toml_float value
  | Otoml.TomlBoolean value -> Toml_bool value
  | Otoml.TomlOffsetDateTime value -> Toml_offset_datetime value
  | Otoml.TomlLocalDateTime value -> Toml_local_datetime value
  | Otoml.TomlLocalDate value -> Toml_local_date value
  | Otoml.TomlLocalTime value -> Toml_local_time value
  | Otoml.TomlArray values ->
    let values = List.map toml_value_of_otoml values in
    (match
       List.fold_right
         (fun value strings ->
           match value, strings with
           | Toml_string string, Some strings -> Some (string :: strings)
           | Toml_string _, None -> None
           | ( Toml_int _ | Toml_float _ | Toml_bool _ | Toml_string_array _
             | Toml_array _ | Toml_table _ | Toml_inline_table _ | Toml_table_array _
             | Toml_offset_datetime _ | Toml_local_datetime _ | Toml_local_date _
             | Toml_local_time _ ), _ -> None)
         values
         (Some [])
     with
     | Some strings -> Toml_string_array strings
     | None -> Toml_array values)
  | Otoml.TomlTable fields ->
    Toml_table
      (List.map
         (fun (key, value) -> key, toml_value_of_otoml value)
         fields)
  | Otoml.TomlInlineTable fields ->
    Toml_inline_table
      (List.map
         (fun (key, value) -> key, toml_value_of_otoml value)
         fields)
  | Otoml.TomlTableArray values ->
    Toml_table_array (List.map toml_value_of_otoml values)
;;

let valid_bare_key key =
  String.length key > 0
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
         | _ -> false)
       key
;;

let canonical_key key =
  if valid_bare_key key then key else Otoml.string_of_path [ key ]
;;

let string_of_path path =
  String.concat "." (List.map canonical_key path)
;;

let rec flatten_table path fields =
  List.concat_map
    (fun (key, value) ->
      let path = path @ [ key ] in
      match value with
      | Otoml.TomlTable nested -> flatten_table path nested
      | value -> [ string_of_path path, toml_value_of_otoml value ])
    fields
;;

let parse_toml content =
  (* TOML defines CRLF and LF as equivalent newlines. Otoml 1.0.5 preserves
     CRLF bytes inside multiline strings, so normalize only CRLF boundaries
     before semantic parsing. *)
  let content =
    content
    |> String.split_on_char '\n'
    |> List.map String_util.strip_trailing_cr
    |> String.concat "\n"
  in
  match Otoml.Parser.from_string_result content with
  | Error message -> Error message
  | Ok (Otoml.TomlTable fields) -> Ok (flatten_table [] fields)
  | Ok _ -> Error "otoml returned a non-table document root"
;;
