module Request_id = Keeper_chat_delivery_identity.Request_id

type accepted_payload =
  { keeper_name : string
  ; submitted_by : string
  ; prompt : string
  ; preset : string
  ; web_tools : bool
  ; topology : Fusion_types.fusion_topology
  ; channel : Keeper_continuation_channel.t
  }

type t =
  { schema_version : int
  ; request_id : Request_id.t
  ; payload : accepted_payload
  ; accepted_at : float
  }

type prepare_outcome =
  | Prepared of t
  | Already_present of t

type publication =
  | Not_published
  | Published_indeterminate

type error =
  | Invalid_base_path of string
  | Invalid_keeper_name of string
  | Invalid_request_id of string
  | Invalid_payload of string
  | Not_found of string
  | Read_failed of string
  | Decode_failed of string
  | Identity_conflict of string
  | Persistence_failed of
      { publication : publication
      ; detail : string
      }
  | Removal_failed of
      { removed : bool
      ; detail : string
      }

type record_failure =
  { path : string
  ; detail : string
  }

type inventory =
  { obligations : t list
  ; record_failures : record_failure list
  }

let schema_version = 1
let active_directory_name = "fusion_delivery_obligations_v1"
let staging_directory_name = ".fusion_delivery_obligations_staging_v1"
let ( let* ) = Result.bind

let publication_to_string = function
  | Not_published -> "not_published"
  | Published_indeterminate -> "published_indeterminate"
;;

let error_to_string = function
  | Invalid_base_path detail -> "invalid Fusion delivery base path: " ^ detail
  | Invalid_keeper_name detail -> "invalid Fusion delivery Keeper name: " ^ detail
  | Invalid_request_id detail -> "invalid Fusion delivery request id: " ^ detail
  | Invalid_payload detail -> "invalid Fusion delivery payload: " ^ detail
  | Not_found path -> "Fusion delivery obligation not found: " ^ path
  | Read_failed detail -> "Fusion delivery obligation read failed: " ^ detail
  | Decode_failed detail -> "Fusion delivery obligation decode failed: " ^ detail
  | Identity_conflict detail -> "Fusion delivery identity conflict: " ^ detail
  | Persistence_failed { publication; detail } ->
    Printf.sprintf
      "Fusion delivery persistence failed: publication=%s detail=%s"
      (publication_to_string publication)
      detail
  | Removal_failed { removed; detail } ->
    Printf.sprintf
      "Fusion delivery removal failed: removed=%b detail=%s"
      removed
      detail
;;

let validate_utf8 field value =
  if String.is_valid_utf_8 value
  then Ok ()
  else Error (Invalid_payload (field ^ " contains malformed UTF-8"))
;;

let validate_nonblank field value =
  let* () = validate_utf8 field value in
  let trimmed = String.trim value in
  if String.equal trimmed ""
  then Error (Invalid_payload (field ^ " must not be blank"))
  else if not (String.equal trimmed value)
  then Error (Invalid_payload (field ^ " must not have surrounding whitespace"))
  else Ok ()
;;

let validate_payload (payload : accepted_payload) =
  let* _keeper =
    Keeper_id.Keeper_name.of_string payload.keeper_name
    |> Result.map_error (fun detail -> Invalid_keeper_name detail)
  in
  let* () = validate_nonblank "submitted_by" payload.submitted_by in
  let* () = validate_nonblank "prompt" payload.prompt in
  let* () = validate_utf8 "preset" payload.preset in
  Keeper_continuation_channel.to_yojson payload.channel
  |> Keeper_continuation_channel.of_yojson
  |> Result.map (fun _ -> ())
  |> Result.map_error (fun detail -> Invalid_payload detail)
;;

let validate_record record =
  if record.schema_version <> schema_version
  then
    Error
      (Decode_failed
         (Printf.sprintf "unsupported schema version %d" record.schema_version))
  else if not (Float.is_finite record.accepted_at)
  then Error (Invalid_payload "accepted_at must be finite")
  else
    let* _request_id =
      Request_id.of_string (Request_id.to_string record.request_id)
      |> Result.map_error (fun detail -> Invalid_request_id detail)
    in
    validate_payload record.payload
;;

let canonical_base_path base_path =
  let normalized = Workspace_utils_backend_setup.normalize_base_path base_path in
  if String.equal normalized ""
  then Error (Invalid_base_path "base_path is empty")
  else
    try Ok (Fs_compat.realpath normalized) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Invalid_base_path (Printexc.to_string exn))
;;

let obligation_root ~base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "fusion_delivery_obligations"
;;

let active_dir ~base_path =
  Filename.concat (obligation_root ~base_path) active_directory_name
;;

let staging_dir ~base_path =
  Filename.concat (obligation_root ~base_path) staging_directory_name
;;

let record_path ~base_path request_id =
  Filename.concat (active_dir ~base_path) (Request_id.to_string request_id)
;;

let topology_to_yojson topology =
  `String (Fusion_types.fusion_topology_to_string topology)
;;

let payload_to_yojson (payload : accepted_payload) =
  `Assoc
    [ "keeper_name", `String payload.keeper_name
    ; "submitted_by", `String payload.submitted_by
    ; "prompt", `String payload.prompt
    ; "preset", `String payload.preset
    ; "web_tools", `Bool payload.web_tools
    ; "topology", topology_to_yojson payload.topology
    ; "channel", Keeper_continuation_channel.to_yojson payload.channel
    ]
;;

let to_yojson record =
  `Assoc
    [ "schema_version", `Int record.schema_version
    ; "request_id", `String (Request_id.to_string record.request_id)
    ; "payload", payload_to_yojson record.payload
    ; "accepted_at", `Float record.accepted_at
    ]
;;

let validate_fields ~context ~expected fields =
  let rec loop seen = function
    | [] ->
      (match List.find_opt (fun name -> not (List.mem name seen)) expected with
       | None -> Ok ()
       | Some name -> Error (Decode_failed (Printf.sprintf "%s missing field %S" context name)))
    | (name, _) :: rest ->
      if List.mem name seen
      then Error (Decode_failed (Printf.sprintf "%s duplicate field %S" context name))
      else if not (List.mem name expected)
      then Error (Decode_failed (Printf.sprintf "%s unknown field %S" context name))
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Decode_failed (Printf.sprintf "missing field %S" name))
;;

let string_field name fields =
  let* value = field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Decode_failed (Printf.sprintf "field %S must be a string" name))
;;

let bool_field name fields =
  let* value = field name fields in
  match value with
  | `Bool value -> Ok value
  | _ -> Error (Decode_failed (Printf.sprintf "field %S must be a bool" name))
;;

let int_field name fields =
  let* value = field name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Decode_failed (Printf.sprintf "field %S must be an int" name))
;;

let float_field name fields =
  let* value = field name fields in
  match value with
  | `Float value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | _ -> Error (Decode_failed (Printf.sprintf "field %S must be numeric" name))
;;

let payload_of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"Fusion delivery payload"
        ~expected:
          [ "keeper_name"
          ; "submitted_by"
          ; "prompt"
          ; "preset"
          ; "web_tools"
          ; "topology"
          ; "channel"
          ]
        fields
    in
    let* keeper_name = string_field "keeper_name" fields in
    let* submitted_by = string_field "submitted_by" fields in
    let* prompt = string_field "prompt" fields in
    let* preset = string_field "preset" fields in
    let* web_tools = bool_field "web_tools" fields in
    let* topology_wire = string_field "topology" fields in
    let* topology =
      match Fusion_types.fusion_topology_of_string topology_wire with
      | Some topology -> Ok topology
      | None -> Error (Decode_failed (Printf.sprintf "unknown Fusion topology %S" topology_wire))
    in
    let* channel_json = field "channel" fields in
    let* channel =
      Keeper_continuation_channel.of_yojson channel_json
      |> Result.map_error (fun detail -> Decode_failed detail)
    in
    let payload =
      { keeper_name
      ; submitted_by
      ; prompt
      ; preset
      ; web_tools
      ; topology
      ; channel
      }
    in
    let* () = validate_payload payload in
    Ok payload
  | _ -> Error (Decode_failed "Fusion delivery payload must be an object")
;;

let of_yojson = function
  | `Assoc fields ->
    let* () =
      validate_fields
        ~context:"Fusion delivery obligation"
        ~expected:[ "schema_version"; "request_id"; "payload"; "accepted_at" ]
        fields
    in
    let* schema_version = int_field "schema_version" fields in
    let* request_id_wire = string_field "request_id" fields in
    let* request_id =
      Request_id.of_string request_id_wire
      |> Result.map_error (fun detail -> Invalid_request_id detail)
    in
    let* payload_json = field "payload" fields in
    let* payload = payload_of_yojson payload_json in
    let* accepted_at = float_field "accepted_at" fields in
    let record = { schema_version; request_id; payload; accepted_at } in
    let* () = validate_record record in
    Ok record
  | _ -> Error (Decode_failed "Fusion delivery obligation must be an object")
;;

let same_record left right =
  Request_id.equal left.request_id right.request_id
  && Float.equal left.accepted_at right.accepted_at
  && Yojson.Safe.equal (payload_to_yojson left.payload) (payload_to_yojson right.payload)
;;

type operation_lock =
  { mutex : Eio.Mutex.t
  ; mutable users : int
  }

let operation_locks : (string, operation_lock) Hashtbl.t = Hashtbl.create 16
let operation_locks_mutex = Stdlib.Mutex.create ()

let acquire_operation_lock path =
  Stdlib.Mutex.protect operation_locks_mutex (fun () ->
    match Hashtbl.find_opt operation_locks path with
    | Some lock ->
      lock.users <- lock.users + 1;
      lock
    | None ->
      let lock = { mutex = Eio.Mutex.create (); users = 1 } in
      Hashtbl.add operation_locks path lock;
      lock)
;;

let release_operation_lock path lock =
  Stdlib.Mutex.protect operation_locks_mutex (fun () ->
    lock.users <- lock.users - 1;
    if lock.users = 0
    then
      match Hashtbl.find_opt operation_locks path with
      | Some current when current == lock -> Hashtbl.remove operation_locks path
      | Some _ | None -> ())
;;

let with_operation_lock path f =
  let lock = acquire_operation_lock path in
  Fun.protect
    ~finally:(fun () -> release_operation_lock path lock)
    (fun () -> Eio.Mutex.use_rw ~protect:true lock.mutex f)
;;

let load_path_unlocked ~base_path path =
  match Fs_compat.load_owned_regular_file ~ownership_root:base_path path with
  | Error error ->
    Error
      (Read_failed
         (Fs_compat.owned_regular_file_read_error_to_string error))
  | Ok None -> Error (Not_found path)
  | Ok (Some content) ->
    (try Yojson.Safe.from_string content |> of_yojson with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Yojson.Json_error detail -> Error (Decode_failed detail)
     | exn -> Error (Decode_failed (Printexc.to_string exn)))
;;

let prepare ~base_path ~request_id ~payload ~accepted_at =
  let record = { schema_version; request_id; payload; accepted_at } in
  let* () = validate_record record in
  let* base_path = canonical_base_path base_path in
  let path = record_path ~base_path request_id in
  with_operation_lock path (fun () ->
    match load_path_unlocked ~base_path path with
    | Ok existing when same_record existing record -> Ok (Already_present existing)
    | Ok _ ->
      Error
        (Identity_conflict
           (Printf.sprintf
              "request_id=%S already has a different accepted payload"
              (Request_id.to_string request_id)))
    | Error (Not_found _) ->
      Keeper_fs.save_json_durable_atomic
        ~ownership_root:base_path
        ~temp_dir:(staging_dir ~base_path)
        path
        (to_yojson record)
      |> Result.map (fun () -> Prepared record)
      |> Result.map_error (fun error ->
        Persistence_failed
          { publication =
              (if error.Keeper_fs.renamed
               then Published_indeterminate
               else Not_published)
          ; detail = Keeper_fs.durable_write_error_to_string error
          })
    | Error error -> Error error)
;;

let load ~base_path ~request_id =
  let* base_path = canonical_base_path base_path in
  let* request_id =
    Request_id.of_string (Request_id.to_string request_id)
    |> Result.map_error (fun detail -> Invalid_request_id detail)
  in
  let path = record_path ~base_path request_id in
  with_operation_lock path (fun () -> load_path_unlocked ~base_path path)
;;

let remove_delivered ~base_path ~identity =
  let* base_path = canonical_base_path base_path in
  let path = record_path ~base_path identity.request_id in
  with_operation_lock path (fun () ->
    match load_path_unlocked ~base_path path with
    | Error (Not_found _) -> Ok ()
    | Error error -> Error error
    | Ok existing when not (same_record existing identity) ->
      Error (Identity_conflict "delivery removal identity changed")
    | Ok _ ->
      Keeper_fs.remove_file_durable ~ownership_root:base_path path
      |> Result.map_error (fun error ->
        Removal_failed
          { removed = error.Keeper_fs.removed
          ; detail = Keeper_fs.durable_remove_error_to_string error
          }))
;;

let inventory ~base_path =
  let* base_path = canonical_base_path base_path in
  let directory = active_dir ~base_path in
  let observation =
    Fs_compat.inspect_owned_directory_chain ~ownership_root:base_path directory
  in
  match observation with
  | Error rejection ->
    Error
      (Read_failed
         (Fs_compat.owned_directory_chain_rejection_to_string rejection))
  | Ok Fs_compat.Owned_directory_missing ->
    Ok { obligations = []; record_failures = [] }
  | Ok (Fs_compat.Owned_directory _) ->
    let names =
      try Ok (Fs_compat.read_dir directory) with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Read_failed (Printexc.to_string exn))
    in
    let* names = names in
    List.fold_left
      (fun (obligations, failures) name ->
        Eio_guard.fair_yield ();
        let path = Filename.concat directory name in
        match Request_id.of_string name with
        | Error detail ->
          obligations, { path; detail = "invalid filename: " ^ detail } :: failures
        | Ok request_id ->
          (match
             with_operation_lock path (fun () ->
               load_path_unlocked ~base_path path)
           with
           | Ok record when Request_id.equal record.request_id request_id ->
             record :: obligations, failures
           | Ok _ ->
             obligations,
             { path; detail = "filename and record request identity differ" }
             :: failures
           | Error error ->
             obligations, { path; detail = error_to_string error } :: failures))
      ([], [])
      names
    |> fun (obligations, record_failures) ->
    Ok
      { obligations = List.rev obligations
      ; record_failures = List.rev record_failures
      }
;;

let cleanup_staging_for_startup ~base_path =
  let* base_path = canonical_base_path base_path in
  let staging = staging_dir ~base_path in
  let report =
    Eio_guard.run_in_systhread (fun () ->
      Fs_compat.cleanup_atomic_orphans
        ~ownership_root:base_path
        ~base_path:staging
        ~scope:Fs_compat.Directory_only
        ())
  in
  Eio_guard.check_if_ready ();
  Ok report
;;

module For_testing = struct
  let active_directory ~base_path =
    canonical_base_path base_path |> Result.map (fun base_path -> active_dir ~base_path)
  ;;

  let staging_directory ~base_path =
    canonical_base_path base_path |> Result.map (fun base_path -> staging_dir ~base_path)
  ;;
end
