let ( let* ) = Result.bind

type t =
  { base_path : string
  ; worker_name : string
  ; model_label : string
  ; working_dir : string option
  ; runtime_backend : Worker_execution_backend.t
  ; thinking_enabled : bool option
  ; worker_run_id : string option
  ; role : string option
  ; selection_note : string option
  ; prompt : string
  ; timeout_sec : int
  }

let option_to_yojson to_json = function
  | Some value -> to_json value
  | None -> `Null
;;

let required_trimmed_string field = function
  | `String value ->
    let trimmed = String.trim value in
    if trimmed = "" then Error (field ^ " must not be empty") else Ok trimmed
  | _ -> Error (field ^ " must be a string")
;;

let option_string json =
  match json with
  | `String value ->
    let trimmed = String.trim value in
    if trimmed = "" then None else Some trimmed
  | `Null -> None
  | _ -> None
;;

let allowed_fields =
  [ "base_path"
  ; "worker_name"
  ; "model_label"
  ; "working_dir"
  ; "runtime_backend"
  ; "thinking_enabled"
  ; "worker_run_id"
  ; "role"
  ; "selection_note"
  ; "prompt"
  ; "timeout_sec"
  ]
;;

let removed_fields =
  [ "worker_class"; "max_turns"; "allowed_tools"; "allowed_shell_tools" ]
;;

let validate_fields fields =
  let field_names = List.map fst fields in
  match List.find_opt (fun name -> List.mem name removed_fields) field_names with
  | Some field ->
    Error
      (Printf.sprintf
         "worker execution spec field %S has been removed; use runtime_backend + fixed \
          worker surfaces"
         field)
  | None ->
    (match List.find_opt (fun name -> not (List.mem name allowed_fields)) field_names with
     | Some field -> Error (Printf.sprintf "unknown worker execution spec field %S" field)
     | None -> Ok ())
;;

let to_yojson (spec : t) =
  `Assoc
    [ "base_path", `String spec.base_path
    ; "worker_name", `String spec.worker_name
    ; "model_label", `String spec.model_label
    ; "working_dir", option_to_yojson (fun s -> `String s) spec.working_dir
    ; "runtime_backend", Worker_execution_backend.to_yojson spec.runtime_backend
    ; "thinking_enabled", option_to_yojson (fun v -> `Bool v) spec.thinking_enabled
    ; "worker_run_id", option_to_yojson (fun s -> `String s) spec.worker_run_id
    ; "role", option_to_yojson (fun s -> `String s) spec.role
    ; "selection_note", option_to_yojson (fun s -> `String s) spec.selection_note
    ; "prompt", `String spec.prompt
    ; "timeout_sec", `Int spec.timeout_sec
    ]
;;

let of_yojson (json : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  match json with
  | `Assoc fields ->
    (try
       let* () = validate_fields fields in
       let* base_path =
         required_trimmed_string "base_path" (json |> member "base_path")
       in
       let* worker_name =
         required_trimmed_string "worker_name" (json |> member "worker_name")
       in
       let* model_label =
         required_trimmed_string "model_label" (json |> member "model_label")
       in
       let* prompt = required_trimmed_string "prompt" (json |> member "prompt") in
       let* runtime_backend =
         Worker_execution_backend.of_yojson (json |> member "runtime_backend")
       in
       let timeout_sec = json |> member "timeout_sec" |> to_int in
       Ok
         { base_path
         ; worker_name
         ; model_label
         ; working_dir = option_string (json |> member "working_dir")
         ; runtime_backend
         ; thinking_enabled =
             (match json |> member "thinking_enabled" with
              | `Bool value -> Some value
              | `Null -> None
              | _ -> None)
         ; worker_run_id = option_string (json |> member "worker_run_id")
         ; role = option_string (json |> member "role")
         ; selection_note = option_string (json |> member "selection_note")
         ; prompt
         ; timeout_sec
         }
     with
     | Yojson.Json_error msg -> Error ("worker execution spec JSON error: " ^ msg)
     | Type_error (msg, _) -> Error ("worker execution spec type error: " ^ msg)
     | Failure msg -> Error msg)
  | _ -> Error "worker execution spec must be a JSON object"
;;
