let ( let* ) = Result.bind

type t = {
  base_path : string;
  worker_name : string;
  model_label : string;
  working_dir : string option;
  worker_class : Worker_types.worker_class option;
  execution_scope : Worker_types.execution_scope option;
  thinking_enabled : bool option;
  max_turns : int;
  worker_run_id : string option;
  role : string option;
  selection_note : string option;
  prompt : string;
  allowed_tools : string list;
  allowed_shell_tools : string list;
  timeout_sec : int;
}

let option_to_yojson to_json = function
  | Some value -> to_json value
  | None -> `Null

let required_trimmed_string field = function
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then Error (field ^ " must not be empty") else Ok trimmed
  | _ -> Error (field ^ " must be a string")

let option_string json =
  match json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | `Null -> None
  | _ -> None

let string_list_of_yojson = function
  | `List values ->
      values
      |> List.filter_map (function
           | `String value ->
               let trimmed = String.trim value in
               if trimmed = "" then None else Some trimmed
           | _ -> None)
  | _ -> []

let execution_scope_to_yojson = function
  | Some scope ->
      `String (Worker_types.execution_scope_to_string scope)
  | None -> `Null

let execution_scope_of_yojson = function
  | `String value ->
      Some
        (Worker_types.execution_scope_of_string
           (String.lowercase_ascii (String.trim value)))
  | `Null -> None
  | _ -> None

let worker_class_to_yojson = function
  | Some worker_class ->
      `String (Worker_types.worker_class_to_string worker_class)
  | None -> `Null

let worker_class_of_yojson = function
  | `String value ->
      Worker_types.worker_class_of_string
        (String.lowercase_ascii (String.trim value))
  | `Null -> None
  | _ -> None

let to_yojson (spec : t) =
  `Assoc
    [
      ("base_path", `String spec.base_path);
      ("worker_name", `String spec.worker_name);
      ("model_label", `String spec.model_label);
      ("working_dir", option_to_yojson (fun s -> `String s) spec.working_dir);
      ("worker_class", worker_class_to_yojson spec.worker_class);
      ("execution_scope", execution_scope_to_yojson spec.execution_scope);
      ("thinking_enabled", option_to_yojson (fun v -> `Bool v) spec.thinking_enabled);
      ("max_turns", `Int spec.max_turns);
      ("worker_run_id", option_to_yojson (fun s -> `String s) spec.worker_run_id);
      ("role", option_to_yojson (fun s -> `String s) spec.role);
      ("selection_note", option_to_yojson (fun s -> `String s) spec.selection_note);
      ("prompt", `String spec.prompt);
      ("allowed_tools", `List (List.map (fun value -> `String value) spec.allowed_tools));
      ( "allowed_shell_tools",
        `List
          (List.map (fun value -> `String value) spec.allowed_shell_tools) );
      ("timeout_sec", `Int spec.timeout_sec);
    ]

let of_yojson (json : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  match json with
  | `Assoc _ ->
      (try
         let* base_path =
           required_trimmed_string "base_path" (json |> member "base_path")
         in
         let* worker_name =
           required_trimmed_string "worker_name" (json |> member "worker_name")
         in
         let* model_label =
           required_trimmed_string "model_label" (json |> member "model_label")
         in
         let* prompt =
           required_trimmed_string "prompt" (json |> member "prompt")
         in
         let max_turns = json |> member "max_turns" |> to_int in
         let timeout_sec = json |> member "timeout_sec" |> to_int in
         Ok
           {
             base_path;
             worker_name;
             model_label;
             working_dir = option_string (json |> member "working_dir");
             worker_class = worker_class_of_yojson (json |> member "worker_class");
             execution_scope =
               execution_scope_of_yojson (json |> member "execution_scope");
             thinking_enabled =
               (match json |> member "thinking_enabled" with
               | `Bool value -> Some value
               | `Null -> None
               | _ -> None);
             max_turns;
             worker_run_id = option_string (json |> member "worker_run_id");
             role = option_string (json |> member "role");
             selection_note = option_string (json |> member "selection_note");
             prompt;
             allowed_tools = string_list_of_yojson (json |> member "allowed_tools");
             allowed_shell_tools =
               string_list_of_yojson (json |> member "allowed_shell_tools");
             timeout_sec;
           }
       with
       | Yojson.Json_error msg -> Error ("worker execution spec JSON error: " ^ msg)
       | Type_error (msg, _) -> Error ("worker execution spec type error: " ^ msg)
       | Failure msg -> Error msg)
  | _ -> Error "worker execution spec must be a JSON object"
