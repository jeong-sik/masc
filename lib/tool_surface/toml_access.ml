(* See toml_access.mli. *)

let sprintf = Printf.sprintf
open Result.Syntax

let shape = function
  | Otoml.TomlString _ -> "a string"
  | Otoml.TomlInteger _ -> "an integer"
  | Otoml.TomlFloat _ -> "a float"
  | Otoml.TomlBoolean _ -> "a boolean"
  | Otoml.TomlOffsetDateTime _ -> "an offset datetime"
  | Otoml.TomlLocalDateTime _ -> "a local datetime"
  | Otoml.TomlLocalDate _ -> "a local date"
  | Otoml.TomlLocalTime _ -> "a local time"
  | Otoml.TomlArray _ -> "an array"
  | Otoml.TomlTable _ -> "a table"
  | Otoml.TomlInlineTable _ -> "an inline table"
  | Otoml.TomlTableArray _ -> "an array of tables"
;;

let as_string ~context = function
  | Otoml.TomlString value -> Ok value
  | ( Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be a string, got %s" context (shape other))
;;

let as_non_empty_string ~context value =
  let* text = as_string ~context value in
  if String.equal (String.trim text) ""
  then Error (sprintf "%s must not be empty" context)
  else Ok text
;;

let as_bool ~context = function
  | Otoml.TomlBoolean value -> Ok value
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be a boolean, got %s" context (shape other))
;;

let as_int ~context = function
  | Otoml.TomlInteger value -> Ok value
  | ( Otoml.TomlString _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be an integer, got %s" context (shape other))
;;

(* TOML tells 0.0 from 0, and so does the schema: a float bound serializes as
   0.0 and an integer one as 0. Accepting an integer here would move the bytes
   of every declaration that carries one. *)
let as_float ~context = function
  | Otoml.TomlFloat value -> Ok value
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be a float, got %s" context (shape other))
;;

let as_table_pairs ~context = function
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs -> Ok pairs
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlArray _ | Otoml.TomlTableArray _ ) as other ->
    Error (sprintf "%s must be a table, got %s" context (shape other))
;;

let as_table_array ~context = function
  | Otoml.TomlTableArray tables -> Ok tables
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlArray _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ) as other ->
    Error (sprintf "%s must be an array of tables, got %s" context (shape other))
;;

let as_string_list ~context value =
  let element index item =
    as_string ~context:(sprintf "%s[%d]" context index) item
  in
  match value with
  | Otoml.TomlArray items ->
    let rec collect index acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* text = element index item in
        collect (index + 1) (text :: acc) rest
    in
    collect 0 [] items
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be an array of strings, got %s" context (shape other))
;;

let as_int_list ~context value =
  let element index item = as_int ~context:(sprintf "%s[%d]" context index) item in
  match value with
  | Otoml.TomlArray items ->
    let rec collect index acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* v = element index item in
        collect (index + 1) (v :: acc) rest
    in
    collect 0 [] items
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be an array of integers, got %s" context (shape other))
;;
