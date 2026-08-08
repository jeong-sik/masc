type phase =
  | Claimed of { previous_session_id : string option }
  | Settled of { session_id : string }

type t =
  { runtime_id : string
  ; phase : phase
  ; turn_count : int
  ; last_usage : Runtime_claude_code_cli.usage option
  ; updated_at : float
  }

let ( let* ) = Result.bind
let schema = "masc.keeper.claude-code-session.v1"
let filename = "claude-code-session.json"
let state_dirname = "official-client-runtime"
let lock_filename = "claude-code-session.lock"

let state_dir ~base_path ~keeper_name =
  if not (Safe_identifier.is_portable_name keeper_name)
  then Error (Printf.sprintf "invalid Claude Code session Keeper name %S" keeper_name)
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

let non_empty field value =
  if String.trim value = ""
  then Error (Printf.sprintf "Claude Code session %s must not be empty" field)
  else Ok ()
;;

let valid_session_id value =
  if String.length value = 36 && Option.is_some (Uuidm.of_string value)
  then Ok ()
  else Error "Claude Code session_id must be a UUID"
;;

let validate_usage (usage : Runtime_claude_code_cli.usage) =
  if
    usage.input_tokens < 0
    || usage.output_tokens < 0
    || usage.cache_creation_input_tokens < 0
    || usage.cache_read_input_tokens < 0
  then Error "Claude Code session usage must be non-negative"
  else if not (Float.is_finite usage.total_cost_usd) || usage.total_cost_usd < 0.0
  then Error "Claude Code session cost must be finite and non-negative"
  else Ok ()
;;

let validate_phase = function
  | Claimed { previous_session_id = None } -> Ok ()
  | Claimed { previous_session_id = Some session_id }
  | Settled { session_id } -> valid_session_id session_id
;;

let validate state =
  let* () = non_empty "runtime_id" state.runtime_id in
  let* () = validate_phase state.phase in
  let* () =
    match state.last_usage with
    | None -> Ok ()
    | Some usage -> validate_usage usage
  in
  if state.turn_count <= 0
  then Error "Claude Code session turn_count must be positive"
  else if not (Float.is_finite state.updated_at)
  then Error "Claude Code session updated_at must be finite"
  else Ok ()
;;

let phase_to_yojson = function
  | Claimed { previous_session_id } ->
    `Assoc
      [ "kind", `String "claimed"
      ; ( "previous_session_id"
        , Option.fold
            ~none:`Null
            ~some:(fun session_id -> `String session_id)
            previous_session_id )
      ]
  | Settled { session_id } ->
    `Assoc
      [ "kind", `String "settled"
      ; "session_id", `String session_id
      ]
;;

let phase_of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "kind", `String "claimed"; "previous_session_id", `Null ] ->
       Ok (Claimed { previous_session_id = None })
     | [ "kind", `String "claimed"
       ; "previous_session_id", `String session_id
       ] ->
       Ok (Claimed { previous_session_id = Some session_id })
     | [ "session_id", `String session_id
       ; "kind", `String "settled"
       ] -> Ok (Settled { session_id })
     | _ -> Error "Claude Code session phase fields are not exact")
  | _ -> Error "Claude Code session phase must be a JSON object"
;;

let usage_to_yojson (usage : Runtime_claude_code_cli.usage) =
  `Assoc
    [ "cache_creation_input_tokens", `Int usage.cache_creation_input_tokens
    ; "cache_read_input_tokens", `Int usage.cache_read_input_tokens
    ; "input_tokens", `Int usage.input_tokens
    ; "output_tokens", `Int usage.output_tokens
    ; "total_cost_usd", `Float usage.total_cost_usd
    ]
;;

let usage_of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "cache_creation_input_tokens", `Int cache_creation_input_tokens
       ; "cache_read_input_tokens", `Int cache_read_input_tokens
       ; "input_tokens", `Int input_tokens
       ; "output_tokens", `Int output_tokens
       ; "total_cost_usd", `Float total_cost_usd
       ] ->
       let usage : Runtime_claude_code_cli.usage =
         { input_tokens
         ; output_tokens
         ; cache_creation_input_tokens
         ; cache_read_input_tokens
         ; total_cost_usd
         }
       in
       let* () = validate_usage usage in
       Ok usage
     | _ -> Error "Claude Code session usage fields are not exact")
  | _ -> Error "Claude Code session usage must be a JSON object"
;;

let to_yojson state =
  `Assoc
    [ ( "last_usage"
      , Option.fold ~none:`Null ~some:usage_to_yojson state.last_usage )
    ; "phase", phase_to_yojson state.phase
    ; "runtime_id", `String state.runtime_id
    ; "schema", `String schema
    ; "turn_count", `Int state.turn_count
    ; "updated_at", `Float state.updated_at
    ]
;;

let of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "last_usage", last_usage_json
       ; "phase", phase_json
       ; "runtime_id", `String runtime_id
       ; "schema", `String encoded_schema
       ; "turn_count", `Int turn_count
       ; "updated_at", `Float updated_at
       ] ->
       if encoded_schema <> schema
       then Error "unsupported Claude Code session schema"
       else
         let* phase = phase_of_yojson phase_json in
         let* last_usage =
           match last_usage_json with
           | `Null -> Ok None
           | json -> Result.map Option.some (usage_of_yojson json)
         in
         let state = { runtime_id; phase; turn_count; last_usage; updated_at } in
         let* () = validate state in
         Ok state
     | _ -> Error "Claude Code session fields are not exact")
  | _ -> Error "Claude Code session must be a JSON object"
;;

let equal left right =
  String.equal left.runtime_id right.runtime_id
  && left.phase = right.phase
  && Int.equal left.turn_count right.turn_count
  && left.last_usage = right.last_usage
  && Float.equal left.updated_at right.updated_at
;;

let load_path state_path =
  if not (Fs_compat.file_exists state_path)
  then Ok None
  else
    let* json = Safe_ops.read_json_file_safe state_path in
    let* state = of_yojson json in
    Ok (Some state)
;;

let load ~base_path ~keeper_name =
  let* state_path = path ~base_path ~keeper_name in
  load_path state_path
;;

let save_path ~state_dir state =
  let* () = validate state in
  let state_path = Filename.concat state_dir filename in
  let* () =
    match
      Keeper_fs.save_json_durable_atomic
        ~ownership_root:state_dir
        ~pretty:false
        state_path
        (to_yojson state)
    with
    | Ok () -> Ok ()
    | Error error -> Error (Keeper_fs.durable_write_error_to_string error)
  in
  let* persisted = load_path state_path in
  match persisted with
  | Some persisted when equal persisted state -> Ok ()
  | Some _ -> Error "Claude Code session changed after durable write"
  | None -> Error "Claude Code session missing after durable write"
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
    else Error "Claude Code session changed before durable transition")
;;

let claim ~base_path ~keeper_name ~expected ~runtime_id ~updated_at =
  let* () =
    match expected with
    | Some state when not (String.equal state.runtime_id runtime_id) ->
      Error "Claude Code session runtime_id cannot change during claim"
    | None | Some _ -> Ok ()
  in
  let* previous_session_id, turn_count, last_usage =
    match expected with
    | None -> Ok (None, 1, None)
    | Some { phase = Settled { session_id }; turn_count; last_usage; _ }
      when turn_count < Int.max_int ->
      Ok (Some session_id, turn_count + 1, last_usage)
    | Some { phase = Settled _; _ } ->
      Error "settled Claude Code session turn count cannot be incremented"
    | Some { phase = Claimed _; _ } ->
      Error "Claude Code session has an unsettled claim; refusing duplicate execution"
  in
  transition
    ~base_path
    ~keeper_name
    ~expected
    { runtime_id
    ; phase = Claimed { previous_session_id }
    ; turn_count
    ; last_usage
    ; updated_at
    }
;;

let settle ~base_path ~keeper_name ~expected ~session_id ~usage ~updated_at =
  match expected.phase with
  | Settled _ -> Error "Claude Code session can settle only from a claim"
  | Claimed { previous_session_id } ->
    let* () =
      match previous_session_id with
      | None when expected.turn_count = 1 -> Ok ()
      | Some previous when expected.turn_count >= 2 && String.equal previous session_id ->
        Ok ()
      | None | Some _ -> Error "Claude Code settlement session identity changed"
    in
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with
        phase = Settled { session_id }
      ; last_usage = Some usage
      ; updated_at
      }
;;
