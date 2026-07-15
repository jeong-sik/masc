type error =
  | Invalid_base_path of string
  | Invalid_keeper_name of string
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Decode_failed of
      { path : string
      ; detail : string
      }
  | Owner_mismatch of
      { expected : string
      ; actual : string
      }
  | Write_failed of
      { path : string
      ; cause : Keeper_fs.durable_write_error
      }

type enqueue_result =
  | Enqueued
  | Already_present

type location =
  { base_path : string
  ; keeper_name : string
  ; path : string
  }

type state =
  { keeper_name : string
  ; pending : Keeper_memory_work_request.t list
  }

let schema_version = 1
let queue_filename = "memory-work-queue.json"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_base_path detail -> "invalid Memory work base path: " ^ detail
  | Invalid_keeper_name detail -> detail
  | Read_failed { path; detail } ->
    Printf.sprintf "Memory work queue read failed at %s: %s" path detail
  | Decode_failed { path; detail } ->
    Printf.sprintf "Memory work queue decode failed at %s: %s" path detail
  | Owner_mismatch { expected; actual } ->
    Printf.sprintf
      "Memory work queue owner mismatch: expected %s, found %s"
      expected
      actual
  | Write_failed { path; cause } ->
    Printf.sprintf
      "Memory work queue write failed at %s: %s"
      path
      (Keeper_fs.durable_write_error_to_string cause)
;;

let resolve_location ~base_path ~keeper_name =
  let* base_path =
    Config_dir_resolver.canonical_base_path base_path
    |> Result.map_error (fun error ->
      Invalid_base_path
        (Config_dir_resolver.canonical_base_path_error_to_string error))
  in
  let* keeper_name =
    Keeper_id.Keeper_name.of_string keeper_name
    |> Result.map_error (fun detail -> Invalid_keeper_name detail)
  in
  let keeper_name = Keeper_id.Keeper_name.to_string keeper_name in
  let path =
    Filename.concat
      (Filename.concat
         (Common.keepers_runtime_dir_of_base ~base_path)
         keeper_name)
      queue_filename
  in
  Ok { base_path; keeper_name; path }
;;

let queue_path ~base_path ~keeper_name =
  resolve_location ~base_path ~keeper_name |> Result.map (fun location -> location.path)
;;

let state_to_json state =
  `Assoc
    [ "schema_version", `Int schema_version
    ; "keeper_name", `String state.keeper_name
    ; ( "pending"
      , `List (List.map Keeper_memory_work_request.to_json state.pending) )
    ]
;;

let validate_fields fields =
  let expected = [ "schema_version"; "keeper_name"; "pending" ] in
  let rec loop seen = function
    | [] ->
      (match List.find_opt (fun name -> not (List.mem name seen)) expected with
       | None -> Ok ()
       | Some name -> Error (Printf.sprintf "missing field %S" name))
    | (name, _) :: rest ->
      if List.mem name seen then Error (Printf.sprintf "duplicate field %S" name)
      else if not (List.mem name expected) then
        Error (Printf.sprintf "unknown field %S" name)
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let decode_requests values =
  List.fold_right
    (fun value result ->
       let* rest = result in
       let* request = Keeper_memory_work_request.of_json value in
       Ok (request :: rest))
    values
    (Ok [])
;;

let validate_pending ~keeper_name requests =
  let rec loop seen = function
    | [] -> Ok ()
    | request :: rest ->
      let owner = Keeper_memory_work_request.keeper_name request in
      let request_id = Keeper_memory_work_request.request_id request in
      if not (String.equal owner keeper_name) then
        Error
          (Printf.sprintf
             "request %s belongs to Keeper %s, not %s"
             request_id
             owner
             keeper_name)
      else if List.mem request_id seen then
        Error (Printf.sprintf "duplicate request_id %s" request_id)
      else loop (request_id :: seen) rest
  in
  loop [] requests
;;

let state_of_json = function
  | `Assoc fields ->
    let* () = validate_fields fields in
    let* encoded_schema =
      match List.assoc "schema_version" fields with
      | `Int value -> Ok value
      | _ -> Error "schema_version must be an integer"
    in
    if encoded_schema <> schema_version then
      Error (Printf.sprintf "unsupported schema_version %d" encoded_schema)
    else
      let* keeper_name =
        match List.assoc "keeper_name" fields with
        | `String value -> Ok value
        | _ -> Error "keeper_name must be a string"
      in
      let* pending =
        match List.assoc "pending" fields with
        | `List values -> decode_requests values
        | _ -> Error "pending must be a list"
      in
      let* () = validate_pending ~keeper_name pending in
      Ok { keeper_name; pending }
  | _ -> Error "Memory work queue must be a JSON object"
;;

let load_unlocked location =
  try
    if Sys.file_exists location.path then
      let* json =
        Safe_ops.read_json_file_safe location.path
        |> Result.map_error (fun detail ->
          Read_failed { path = location.path; detail })
      in
      let* state =
        state_of_json json
        |> Result.map_error (fun detail ->
          Decode_failed { path = location.path; detail })
      in
      if String.equal state.keeper_name location.keeper_name then Ok state
      else
        Error
          (Owner_mismatch
             { expected = location.keeper_name; actual = state.keeper_name })
    else Ok { keeper_name = location.keeper_name; pending = [] }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error (Read_failed { path = location.path; detail = Printexc.to_string exn })
;;

let save_unlocked location state =
  Keeper_fs.save_json_durable_atomic
    ~ownership_root:location.base_path
    location.path
    (state_to_json state)
  |> Result.map_error (fun cause -> Write_failed { path = location.path; cause })
;;

let with_location ~base_path ~keeper_name f =
  let* location = resolve_location ~base_path ~keeper_name in
  File_lock_eio.with_mutex location.path (fun () -> f location)
;;

let enqueue ~base_path request =
  let keeper_name = Keeper_memory_work_request.keeper_name request in
  with_location ~base_path ~keeper_name (fun location ->
    let* state = load_unlocked location in
    let request_id = Keeper_memory_work_request.request_id request in
    if
      List.exists
        (fun queued ->
           String.equal
             request_id
             (Keeper_memory_work_request.request_id queued))
        state.pending
    then Ok Already_present
    else
      let state = { state with pending = state.pending @ [ request ] } in
      let* () = save_unlocked location state in
      Ok Enqueued)
;;

let pending ~base_path ~keeper_name =
  with_location ~base_path ~keeper_name (fun location ->
    load_unlocked location |> Result.map (fun state -> state.pending))
;;
