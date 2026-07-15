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
  | No_matching_claim of
      { expected : string option
      ; actual : string
      }
  | Invalid_terminal_outcome of string
  | Settlement_conflict of string
  | Write_failed of
      { path : string
      ; cause : Keeper_fs.durable_write_error
      }

type enqueue_result =
  | Enqueued
  | Already_present

type claim_result =
  | Queue_empty
  | Claim_busy of string
  | Claimed of Keeper_memory_work_request.t

type terminal_outcome =
  | Completed
  | Failed of string

type settle_result =
  | Settled
  | Already_settled

type terminal =
  { request : Keeper_memory_work_request.t
  ; outcome : terminal_outcome
  }

type location =
  { base_path : string
  ; keeper_name : string
  ; path : string
  }

type state =
  { keeper_name : string
  ; pending : Keeper_memory_work_request.t list
  ; in_flight : Keeper_memory_work_request.t option
  ; terminal : terminal list
  }

let schema_version = 2
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
  | No_matching_claim { expected; actual } ->
    Printf.sprintf
      "Memory work claim mismatch: expected %s, found %s"
      (Option.value ~default:"no in-flight request" expected)
      actual
  | Invalid_terminal_outcome detail -> "invalid Memory work outcome: " ^ detail
  | Settlement_conflict request_id ->
    Printf.sprintf "Memory work settlement conflicts for request %s" request_id
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

let terminal_outcome_to_json = function
  | Completed -> `Assoc [ "kind", `String "completed"; "detail", `Null ]
  | Failed detail ->
    `Assoc [ "kind", `String "failed"; "detail", `String detail ]
;;

let terminal_to_json terminal =
  `Assoc
    [ "request", Keeper_memory_work_request.to_json terminal.request
    ; "outcome", terminal_outcome_to_json terminal.outcome
    ]
;;

let state_to_json state =
  `Assoc
    [ "schema_version", `Int schema_version
    ; "keeper_name", `String state.keeper_name
    ; ( "pending"
      , `List (List.map Keeper_memory_work_request.to_json state.pending) )
    ; ( "in_flight"
      , match state.in_flight with
        | None -> `Null
        | Some request -> Keeper_memory_work_request.to_json request )
    ; "terminal", `List (List.map terminal_to_json state.terminal)
    ]
;;

let validate_fields ~expected fields =
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

let validate_requests ~keeper_name requests =
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

let terminal_outcome_of_json = function
  | `Assoc fields ->
    let* () = validate_fields ~expected:[ "kind"; "detail" ] fields in
    (match List.assoc "kind" fields, List.assoc "detail" fields with
     | `String "completed", `Null -> Ok Completed
     | `String "failed", `String detail when String.trim detail <> "" ->
       Ok (Failed detail)
     | `String "failed", `String _ -> Error "failed outcome detail must not be empty"
     | _ -> Error "invalid terminal outcome")
  | _ -> Error "terminal outcome must be a JSON object"
;;

let terminal_of_json = function
  | `Assoc fields ->
    let* () = validate_fields ~expected:[ "request"; "outcome" ] fields in
    let* request =
      Keeper_memory_work_request.of_json (List.assoc "request" fields)
    in
    let* outcome = terminal_outcome_of_json (List.assoc "outcome" fields) in
    Ok { request; outcome }
  | _ -> Error "terminal entry must be a JSON object"
;;

let decode_terminal values =
  List.fold_right
    (fun value result ->
       let* rest = result in
       let* terminal = terminal_of_json value in
       Ok (terminal :: rest))
    values
    (Ok [])
;;

let state_of_json = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~expected:
          [ "schema_version"; "keeper_name"; "pending"; "in_flight"; "terminal" ]
        fields
    in
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
      let* in_flight =
        match List.assoc "in_flight" fields with
        | `Null -> Ok None
        | json -> Keeper_memory_work_request.of_json json |> Result.map Option.some
      in
      let* terminal =
        match List.assoc "terminal" fields with
        | `List values -> decode_terminal values
        | _ -> Error "terminal must be a list"
      in
      let requests =
        pending
        @ Option.to_list in_flight
        @ List.map (fun terminal -> terminal.request) terminal
      in
      let* () = validate_requests ~keeper_name requests in
      Ok { keeper_name; pending; in_flight; terminal }
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
    else
      Ok
        { keeper_name = location.keeper_name
        ; pending = []
        ; in_flight = None
        ; terminal = []
        }
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

let request_id_exists state request_id =
  List.exists
    (fun request ->
       String.equal request_id (Keeper_memory_work_request.request_id request))
    (state.pending
     @ Option.to_list state.in_flight
     @ List.map (fun terminal -> terminal.request) state.terminal)
;;

let enqueue ~base_path request =
  let keeper_name = Keeper_memory_work_request.keeper_name request in
  with_location ~base_path ~keeper_name (fun location ->
    let* state = load_unlocked location in
    let request_id = Keeper_memory_work_request.request_id request in
    if request_id_exists state request_id then Ok Already_present
    else
      let state = { state with pending = state.pending @ [ request ] } in
      let* () = save_unlocked location state in
      Ok Enqueued)
;;

let pending ~base_path ~keeper_name =
  with_location ~base_path ~keeper_name (fun location ->
    load_unlocked location |> Result.map (fun state -> state.pending))
;;

let claim_next ~base_path ~keeper_name =
  with_location ~base_path ~keeper_name (fun location ->
    let* state = load_unlocked location in
    match state.in_flight, state.pending with
    | Some request, _ ->
      Ok (Claim_busy (Keeper_memory_work_request.request_id request))
    | None, [] -> Ok Queue_empty
    | None, request :: pending ->
      let state = { state with pending; in_flight = Some request } in
      let* () = save_unlocked location state in
      Ok (Claimed request))
;;

let recover_in_flight ~base_path ~keeper_name =
  with_location ~base_path ~keeper_name (fun location ->
    load_unlocked location |> Result.map (fun state -> state.in_flight))
;;

let equal_terminal_outcome left right =
  match left, right with
  | Completed, Completed -> true
  | Failed left, Failed right -> String.equal left right
  | Completed, Failed _ | Failed _, Completed -> false
;;

let settle ~base_path ~keeper_name ~request_id outcome =
  let* () =
    match outcome with
    | Completed -> Ok ()
    | Failed detail when String.trim detail <> "" -> Ok ()
    | Failed _ -> Error (Invalid_terminal_outcome "failure detail must not be empty")
  in
  with_location ~base_path ~keeper_name (fun location ->
    let* state = load_unlocked location in
    match
      List.find_opt
        (fun terminal ->
           String.equal
             request_id
             (Keeper_memory_work_request.request_id terminal.request))
        state.terminal
    with
    | Some terminal when equal_terminal_outcome terminal.outcome outcome ->
      Ok Already_settled
    | Some _ -> Error (Settlement_conflict request_id)
    | None ->
      (match state.in_flight with
       | None -> Error (No_matching_claim { expected = None; actual = request_id })
       | Some request ->
         let expected = Keeper_memory_work_request.request_id request in
         if not (String.equal expected request_id) then
           Error
             (No_matching_claim { expected = Some expected; actual = request_id })
         else
           let state =
             { state with
               in_flight = None
             ; terminal = state.terminal @ [ { request; outcome } ]
             }
           in
           let* () = save_unlocked location state in
           Ok Settled))
;;

let terminal ~base_path ~keeper_name =
  with_location ~base_path ~keeper_name (fun location ->
    load_unlocked location |> Result.map (fun state -> state.terminal))
;;
