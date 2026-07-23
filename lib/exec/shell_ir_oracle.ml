type parse_status =
  | Parsed_ok
  | Parse_error
  | Incomplete
  | Timeout
  | Unavailable

let parse_status_of_string = function
  | "ok" -> Ok Parsed_ok
  | "parse_error" -> Ok Parse_error
  | "incomplete" -> Ok Incomplete
  | "timeout" -> Ok Timeout
  | "unavailable" -> Ok Unavailable
  | other -> Error (Printf.sprintf "unknown parse_status: %s" other)
;;

let string_of_parse_status = function
  | Parsed_ok -> "ok"
  | Parse_error -> "parse_error"
  | Incomplete -> "incomplete"
  | Timeout -> "timeout"
  | Unavailable -> "unavailable"
;;

type features = {
  pipeline : bool;
  redirect : bool;
  heredoc : bool;
  subshell : bool;
  command_substitution : bool;
  variable : bool;
  glob : bool;
  env_assignment : bool;
  process_substitution : bool;
  unknown_enabled : string list;
}

type command = {
  name : string;
  argv : string list;
}

type t = {
  schema_version : int;
  parser : string option;
  command : string;
  parse_status : parse_status;
  features : features;
  commands : command list;
  error : string option;
}

let ( let* ) = Result.bind

let assoc_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let require_field key json =
  match assoc_opt key json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing field: %s" key)
;;

let require_int key json =
  let* value = require_field key json in
  match value with
  | `Int n -> Ok n
  | _ -> Error (Printf.sprintf "%s must be int" key)
;;

let require_string key json =
  let* value = require_field key json in
  match value with
  | `String s -> Ok s
  | _ -> Error (Printf.sprintf "%s must be string" key)
;;

let optional_string key json =
  match assoc_opt key json with
  | None | Some `Null -> Ok None
  | Some (`String s) -> Ok (Some s)
  | Some _ -> Error (Printf.sprintf "%s must be string or null" key)
;;

let string_list key json =
  let* value = require_field key json in
  match value with
  | `List items ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String s :: rest -> loop (s :: acc) rest
      | _ :: _ -> Error (Printf.sprintf "%s must contain only strings" key)
    in
    loop [] items
  | _ -> Error (Printf.sprintf "%s must be string array" key)
;;

let known_feature_names =
  [ "pipeline"
  ; "redirect"
  ; "heredoc"
  ; "subshell"
  ; "command_substitution"
  ; "variable"
  ; "glob"
  ; "env_assignment"
  ; "process_substitution"
  ]
;;

let feature_bool fields key =
  match List.assoc_opt key fields with
  | None -> Ok false
  | Some (`Bool b) -> Ok b
  | Some _ -> Error (Printf.sprintf "features.%s must be bool" key)
;;

let parse_features json =
  let* value = require_field "features" json in
  match value with
  | `Assoc fields ->
    let unknown_enabled =
      List.filter_map
        (fun (key, value) ->
           if List.mem key known_feature_names then None
           else
             match value with
             | `Bool true -> Some key
             | _ -> None)
        fields
    in
    let* pipeline = feature_bool fields "pipeline" in
    let* redirect = feature_bool fields "redirect" in
    let* heredoc = feature_bool fields "heredoc" in
    let* subshell = feature_bool fields "subshell" in
    let* command_substitution = feature_bool fields "command_substitution" in
    let* variable = feature_bool fields "variable" in
    let* glob = feature_bool fields "glob" in
    let* env_assignment = feature_bool fields "env_assignment" in
    let* process_substitution = feature_bool fields "process_substitution" in
    Ok
      { pipeline
      ; redirect
      ; heredoc
      ; subshell
      ; command_substitution
      ; variable
      ; glob
      ; env_assignment
      ; process_substitution
      ; unknown_enabled
      }
  | _ -> Error "features must be object"
;;

let command_of_yojson = function
  | `Assoc _ as json ->
    let* name = require_string "name" json in
    let* argv = string_list "argv" json in
    Ok { name; argv }
  | _ -> Error "commands entries must be objects"
;;

let commands_of_yojson json =
  let* value = require_field "commands" json in
  match value with
  | `List items ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* command = command_of_yojson item in
        loop (command :: acc) rest
    in
    loop [] items
  | _ -> Error "commands must be an array"
;;

let of_yojson json =
  let* schema_version = require_int "schema_version" json in
  let* parser = optional_string "parser" json in
  let* command = require_string "command" json in
  let* parse_status_raw = require_string "parse_status" json in
  let* parse_status = parse_status_of_string parse_status_raw in
  let* features = parse_features json in
  let* commands = commands_of_yojson json in
  let* error = optional_string "error" json in
  Ok { schema_version; parser; command; parse_status; features; commands; error }
;;

let of_string raw =
  try Yojson.Safe.from_string raw |> of_yojson with
  | Yojson.Json_error msg -> Error (Printf.sprintf "invalid JSON: %s" msg)
;;

let feature_names t =
  let f = t.features in
  [ "pipeline", f.pipeline
  ; "redirect", f.redirect
  ; "heredoc", f.heredoc
  ; "subshell", f.subshell
  ; "command_substitution", f.command_substitution
  ; "variable", f.variable
  ; "glob", f.glob
  ; "env_assignment", f.env_assignment
  ; "process_substitution", f.process_substitution
  ]
  |> List.filter_map (fun (name, enabled) -> if enabled then Some name else None)
  |> fun known -> known @ List.map (fun name -> "unknown:" ^ name) f.unknown_enabled
;;

let structural_feature_blockers t =
  let f = t.features in
  [ "redirect", f.redirect
  ; "heredoc", f.heredoc
  ; "subshell", f.subshell
  ; "command_substitution", f.command_substitution
  ; "env_assignment", f.env_assignment
  ; "process_substitution", f.process_substitution
  ]
  |> List.filter_map (fun (name, enabled) -> if enabled then Some name else None)
  |> fun known -> known @ List.map (fun name -> "unknown:" ^ name) f.unknown_enabled
;;

let structural_blockers t =
  match t.parse_status with
  | Parsed_ok -> structural_feature_blockers t
  | (Parse_error | Incomplete | Timeout | Unavailable) as status ->
    [ "parse_status=" ^ string_of_parse_status status ]
;;

let structurally_compatible t =
  match structural_blockers t with
  | [] -> Ok ()
  | blockers ->
    Error
      (Printf.sprintf
         "structured command incompatible with parser facts: %s"
         (String.concat "," blockers))
;;
