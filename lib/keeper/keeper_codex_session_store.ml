type phase =
  | Start of { previous_thread_id : string option }
  | Active of { thread_id : string }
  | Turn_inflight of
      { thread_id : string
      ; turn_id : string option
      }
  | Settled of
      { thread_id : string
      ; turn_id : string
      }

type t =
  { runtime_id : string
  ; phase : phase
  ; turn_count : int
  ; tool_surface_sha256 : string
  ; updated_at : float
  }

let ( let* ) = Result.bind
let schema = "masc.keeper.codex-session.v2"
let filename = "codex-session.json"
let state_dirname = "official-client-runtime"
let lock_filename = "codex-session.lock"

let state_dir ~base_path ~keeper_name =
  if not (Safe_identifier.is_portable_name keeper_name)
  then Error (Printf.sprintf "invalid Codex session Keeper name %S" keeper_name)
  else
    Ok
      (Filename.concat
         (Filename.concat
            (Common.keepers_runtime_dir_of_base ~base_path)
            keeper_name)
         state_dirname)
;;

let path ~base_path ~keeper_name =
  Result.map
    (fun directory -> Filename.concat directory filename)
    (state_dir ~base_path ~keeper_name)
;;

let rec canonical_json = function
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (name, value) -> name, canonical_json value)
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List values -> `List (List.map canonical_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value ->
    value
;;

let tool_surface_sha256 tools =
  let tool_json (tool : Agent_sdk.Tool.t) =
    let parameters =
      List.sort
        (fun (left : Agent_sdk.Types.tool_param) right ->
           String.compare left.name right.name)
        tool.schema.parameters
    in
    `Assoc
      [ "description", `String tool.schema.description
      ; "input_schema", Agent_sdk.Types.params_to_input_schema parameters
      ; "name", `String tool.schema.name
      ]
    |> canonical_json
  in
  tools
  |> List.sort (fun (left : Agent_sdk.Tool.t) right ->
    String.compare left.schema.name right.schema.name)
  |> List.map tool_json
  |> fun tools -> Yojson.Safe.to_string (`List tools)
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let valid_sha256 value =
  String.length value = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value
;;

let non_empty field value =
  if String.equal (String.trim value) ""
  then Error (Printf.sprintf "Codex session %s must not be empty" field)
  else Ok ()
;;

let validate_phase = function
  | Start { previous_thread_id = None } -> Ok ()
  | Start { previous_thread_id = Some thread_id }
  | Active { thread_id }
  | Turn_inflight { thread_id; turn_id = None } ->
    non_empty "thread_id" thread_id
  | Turn_inflight { thread_id; turn_id = Some turn_id }
  | Settled { thread_id; turn_id } ->
    let* () = non_empty "thread_id" thread_id in
    non_empty "turn_id" turn_id
;;

let validate binding =
  let* () = non_empty "runtime_id" binding.runtime_id in
  let* () = validate_phase binding.phase in
  if binding.turn_count <= 0
  then Error "Codex session turn_count must be positive"
  else if not (valid_sha256 binding.tool_surface_sha256)
  then Error "Codex session tool_surface_sha256 must be lowercase SHA-256"
  else if not (Float.is_finite binding.updated_at)
  then Error "Codex session updated_at must be finite"
  else Ok ()
;;

let phase_to_yojson = function
  | Start { previous_thread_id } ->
    `Assoc
      [ "kind", `String "start"
      ; ( "previous_thread_id"
        , Option.fold
            ~none:`Null
            ~some:(fun thread_id -> `String thread_id)
            previous_thread_id )
      ]
  | Active { thread_id } ->
    `Assoc [ "kind", `String "active"; "thread_id", `String thread_id ]
  | Turn_inflight { thread_id; turn_id } ->
    `Assoc
      [ "kind", `String "turn_inflight"
      ; "thread_id", `String thread_id
      ; ( "turn_id"
        , Option.fold ~none:`Null ~some:(fun turn_id -> `String turn_id) turn_id )
      ]
  | Settled { thread_id; turn_id } ->
    `Assoc
      [ "kind", `String "settled"
      ; "thread_id", `String thread_id
      ; "turn_id", `String turn_id
      ]
;;

let phase_of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "kind", `String "start"; "previous_thread_id", `Null ] ->
       Ok (Start { previous_thread_id = None })
     | [ "kind", `String "start"; "previous_thread_id", `String thread_id ] ->
       Ok (Start { previous_thread_id = Some thread_id })
     | [ "kind", `String "active"; "thread_id", `String thread_id ] ->
       Ok (Active { thread_id })
     | [ "kind", `String "turn_inflight"; "thread_id", `String thread_id
       ; "turn_id", `Null ] ->
       Ok (Turn_inflight { thread_id; turn_id = None })
     | [ "kind", `String "turn_inflight"; "thread_id", `String thread_id
       ; "turn_id", `String turn_id ] ->
       Ok (Turn_inflight { thread_id; turn_id = Some turn_id })
     | [ "kind", `String "settled"; "thread_id", `String thread_id
       ; "turn_id", `String turn_id ] ->
       Ok (Settled { thread_id; turn_id })
     | _ -> Error "Codex session phase fields are not exact")
  | _ -> Error "Codex session phase must be a JSON object"
;;

let to_yojson binding =
  `Assoc
    [ "runtime_id", `String binding.runtime_id
    ; "phase", phase_to_yojson binding.phase
    ; "schema", `String schema
    ; "tool_surface_sha256", `String binding.tool_surface_sha256
    ; "turn_count", `Int binding.turn_count
    ; "updated_at", `Float binding.updated_at
    ]
;;

let of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "phase", phase_json
       ; "runtime_id", `String runtime_id
       ; "schema", `String encoded_schema
       ; "tool_surface_sha256", `String tool_surface_sha256
       ; "turn_count", `Int turn_count
       ; "updated_at", `Float updated_at
       ] ->
       if not (String.equal encoded_schema schema)
       then Error "unsupported Codex session schema"
       else
         let* phase = phase_of_yojson phase_json in
         let binding =
           { runtime_id; phase; turn_count; tool_surface_sha256; updated_at }
         in
         let* () = validate binding in
         Ok binding
     | _ -> Error "Codex session fields are not exact")
  | _ -> Error "Codex session must be a JSON object"
;;

let equal left right =
  String.equal left.runtime_id right.runtime_id
  && left.phase = right.phase
  && Int.equal left.turn_count right.turn_count
  && String.equal left.tool_surface_sha256 right.tool_surface_sha256
  && Float.equal left.updated_at right.updated_at
;;

let load_path state_path =
  if not (Fs_compat.file_exists state_path)
  then Ok None
  else
    let* json = Safe_ops.read_json_file_safe state_path in
    let* binding = of_yojson json in
    Ok (Some binding)
;;

let load ~base_path ~keeper_name =
  let* state_path = path ~base_path ~keeper_name in
  load_path state_path
;;

let save_path ~state_dir binding =
  let* () = validate binding in
  let state_path = Filename.concat state_dir filename in
  let* () =
    match
      Keeper_fs.save_json_durable_atomic
        ~ownership_root:state_dir
        ~pretty:false
        state_path
        (to_yojson binding)
    with
    | Ok () -> Ok ()
    | Error error -> Error (Keeper_fs.durable_write_error_to_string error)
  in
  let* persisted = load_path state_path in
  match persisted with
  | Some persisted when equal persisted binding -> Ok ()
  | Some _ -> Error "Codex session changed after durable write"
  | None -> Error "Codex session missing after durable write"
;;

let prepare_state_dir ~base_path ~keeper_name =
  let* directory = state_dir ~base_path ~keeper_name in
  try
    let (_ : string) = Keeper_fs.ensure_dir directory in
    Ok directory
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let with_store_lock ~base_path ~keeper_name f =
  let* directory = prepare_state_dir ~base_path ~keeper_name in
  match
    File_lock_eio.with_durable_lock
      ~lock_path:(Filename.concat directory lock_filename)
      (fun () -> f directory)
  with
  | Ok result -> result
  | Error error -> Error (File_lock_eio.durable_lock_error_to_string error)
;;

let transition ~base_path ~keeper_name ~expected next =
  let* () = validate next in
  with_store_lock ~base_path ~keeper_name (fun directory ->
    let* current = load_path (Filename.concat directory filename) in
    if Option.equal equal current expected
    then save_path ~state_dir:directory next |> Result.map (fun () -> next)
    else Error "Codex session changed before durable transition")
;;

let claim ~base_path ~keeper_name ~expected ~runtime_id ~tool_surface_sha256
    ~updated_at =
  let* phase, turn_count =
    match expected with
    | None -> Ok (Start { previous_thread_id = None }, 1)
    | Some { phase = Settled { thread_id; _ }; turn_count; _ }
      when turn_count < Int.max_int ->
      Ok (Start { previous_thread_id = Some thread_id }, turn_count + 1)
    | Some { phase = Settled _; _ } ->
      Error "settled Codex session turn count cannot be incremented"
    | Some { phase = Start _; _ } ->
      Error "Codex session has an incomplete thread start; refusing duplicate execution"
    | Some { phase = Active _; _ } ->
      Error "Codex session has an active unsettled attempt; refusing duplicate execution"
    | Some { phase = Turn_inflight _; _ } ->
      Error "Codex session has an in-flight turn; refusing duplicate execution"
  in
  transition
    ~base_path
    ~keeper_name
    ~expected
    { runtime_id; phase; turn_count; tool_surface_sha256; updated_at }
;;

let mark_active ~base_path ~keeper_name ~expected ~thread_id ~updated_at =
  match expected.phase with
  | Start _ ->
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with phase = Active { thread_id }; updated_at }
  | Active _ | Turn_inflight _ | Settled _ ->
    Error "Codex session can become active only from start"
;;

let mark_turn_starting ~base_path ~keeper_name ~expected ~thread_id ~updated_at =
  match expected.phase with
  | Active { thread_id = active_thread_id }
    when String.equal active_thread_id thread_id ->
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with
        phase = Turn_inflight { thread_id; turn_id = None }
      ; updated_at
      }
  | Active _ -> Error "Codex active thread identity changed before turn start"
  | Start _ | Turn_inflight _ | Settled _ ->
    Error "Codex turn can start only from an active session"
;;

let mark_turn_started ~base_path ~keeper_name ~expected ~thread_id ~turn_id
    ~updated_at =
  match expected.phase with
  | Turn_inflight { thread_id = inflight_thread_id; turn_id = None }
    when String.equal inflight_thread_id thread_id ->
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with
        phase = Turn_inflight { thread_id; turn_id = Some turn_id }
      ; updated_at
      }
  | Turn_inflight { turn_id = None; _ } ->
    Error "Codex in-flight thread identity changed after turn start"
  | Turn_inflight { turn_id = Some _; _ } ->
    Error "Codex in-flight turn already has an identity"
  | Start _ | Active _ | Settled _ ->
    Error "Codex turn identity can be recorded only for an in-flight turn"
;;

let settle ~base_path ~keeper_name ~expected ~thread_id ~turn_id ~updated_at =
  match expected.phase with
  | Turn_inflight
      { thread_id = inflight_thread_id; turn_id = Some inflight_turn_id }
    when String.equal inflight_thread_id thread_id
         && String.equal inflight_turn_id turn_id ->
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with phase = Settled { thread_id; turn_id }; updated_at }
  | Turn_inflight _ -> Error "Codex terminal turn identity changed before settlement"
  | Start _ | Active _ | Settled _ ->
    Error "Codex session can settle only from an identified in-flight turn"
;;
