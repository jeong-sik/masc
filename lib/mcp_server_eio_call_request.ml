(** Pure admission for MCP [tools/call] parameters. *)

type t =
  { requested_name : string
  ; arguments : Yojson.Safe.t
  }

type error =
  | Missing_params
  | Expected_object
  | Name_must_be_string
  | Name_must_be_nonempty
  | Name_has_surrounding_whitespace
  | Duplicate_name
  | Arguments_must_be_object of string
  | Duplicate_arguments of string

type field =
  | Absent
  | Present of Yojson.Safe.t
  | Duplicate

let field name fields =
  match List.filter_map (fun (key, value) -> if String.equal key name then Some value else None) fields with
  | [] -> Absent
  | [ value ] -> Present value
  | _ :: _ :: _ -> Duplicate
;;

let decode = function
  | None -> Error Missing_params
  | Some (`Assoc fields) ->
    (match field "name" fields with
     | Absent -> Error Name_must_be_string
     | Duplicate -> Error Duplicate_name
     | Present (`String requested_name) ->
       let canonical_name = String.trim requested_name in
       if String.equal canonical_name ""
       then Error Name_must_be_nonempty
       else if not (String.equal canonical_name requested_name)
       then Error Name_has_surrounding_whitespace
       else (
         match field "arguments" fields with
         | Absent -> Ok { requested_name; arguments = `Assoc [] }
         | Duplicate -> Error (Duplicate_arguments requested_name)
         | Present (`Assoc _ as arguments) -> Ok { requested_name; arguments }
         | Present
             (`Null
             | `Bool _
             | `Int _
             | `Intlit _
             | `Float _
             | `String _
             | `List _)
           ->
           Error (Arguments_must_be_object requested_name))
     | Present
         (`Null
         | `Bool _
         | `Int _
         | `Intlit _
         | `Float _
         | `Assoc _
         | `List _)
       -> Error Name_must_be_string)
  | Some
      (`Null
      | `Bool _
      | `Int _
      | `Intlit _
      | `Float _
      | `String _
      | `List _) ->
    Error Expected_object
;;

let requested_name (request : t) = request.requested_name
let arguments (request : t) = request.arguments

let error_message = function
  | Missing_params -> "Missing params"
  | Expected_object -> "Invalid params: expected object"
  | Name_must_be_string -> "Invalid params: name must be a string"
  | Name_must_be_nonempty -> "Invalid params: name must be a non-empty string"
  | Name_has_surrounding_whitespace ->
    "Invalid params: name must not contain surrounding whitespace"
  | Duplicate_name -> "Invalid params: duplicate name field"
  | Arguments_must_be_object _ -> "Invalid params: arguments must be an object"
  | Duplicate_arguments _ -> "Invalid params: duplicate arguments field"
;;

let error_requested_name = function
  | Arguments_must_be_object requested_name
  | Duplicate_arguments requested_name -> Some requested_name
  | Missing_params
  | Expected_object
  | Name_must_be_string
  | Name_must_be_nonempty
  | Name_has_surrounding_whitespace
  | Duplicate_name -> None
;;
