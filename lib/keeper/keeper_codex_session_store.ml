type t =
  { runtime_id : string
  ; thread_id : string
  ; turn_count : int
  ; tool_surface_sha256 : string
  ; updated_at : float
  }

let ( let* ) = Result.bind
let schema = "masc.keeper.codex-session.v1"
let filename = "codex-session.json"

let path ~session_dir = Filename.concat session_dir filename

let tool_surface_sha256 tools =
  let tool_json (tool : Agent_sdk.Tool.t) =
    `Assoc
      [ "description", `String tool.schema.description
      ; "input_schema", Agent_sdk.Types.params_to_input_schema tool.schema.parameters
      ; "name", `String tool.schema.name
      ]
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

let validate binding =
  if String.equal (String.trim binding.runtime_id) ""
  then Error "Codex session runtime_id must not be empty"
  else if String.equal (String.trim binding.thread_id) ""
  then Error "Codex session thread_id must not be empty"
  else if binding.turn_count <= 0
  then Error "Codex session turn_count must be positive"
  else if not (valid_sha256 binding.tool_surface_sha256)
  then Error "Codex session tool_surface_sha256 must be lowercase SHA-256"
  else if not (Float.is_finite binding.updated_at)
  then Error "Codex session updated_at must be finite"
  else Ok ()
;;

let to_yojson binding =
  `Assoc
    [ "runtime_id", `String binding.runtime_id
    ; "schema", `String schema
    ; "thread_id", `String binding.thread_id
    ; "tool_surface_sha256", `String binding.tool_surface_sha256
    ; "turn_count", `Int binding.turn_count
    ; "updated_at", `Float binding.updated_at
    ]
;;

let of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "runtime_id", `String runtime_id
       ; "schema", `String encoded_schema
       ; "thread_id", `String thread_id
       ; "tool_surface_sha256", `String tool_surface_sha256
       ; "turn_count", `Int turn_count
       ; "updated_at", `Float updated_at
       ] ->
       if not (String.equal encoded_schema schema)
       then Error "unsupported Codex session schema"
       else
         let binding =
           { runtime_id; thread_id; turn_count; tool_surface_sha256; updated_at }
         in
         let* () = validate binding in
         Ok binding
     | _ -> Error "Codex session fields are not exact")
  | _ -> Error "Codex session must be a JSON object"
;;

let equal left right =
  String.equal left.runtime_id right.runtime_id
  && String.equal left.thread_id right.thread_id
  && Int.equal left.turn_count right.turn_count
  && String.equal left.tool_surface_sha256 right.tool_surface_sha256
  && Float.equal left.updated_at right.updated_at
;;

let load ~session_dir =
  let state_path = path ~session_dir in
  if not (Fs_compat.file_exists state_path)
  then Ok None
  else
    let* json = Safe_ops.read_json_file_safe state_path in
    let* binding = of_yojson json in
    Ok (Some binding)
;;

let save ~session_dir binding =
  let* () = validate binding in
  let prepared =
    try
      ignore (Keeper_fs.ensure_dir session_dir : string);
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  in
  let* () = prepared in
  let state_path = path ~session_dir in
  let* () =
    match
      Keeper_fs.save_json_durable_atomic
        ~ownership_root:session_dir
        ~pretty:false
        state_path
        (to_yojson binding)
    with
    | Ok () -> Ok ()
    | Error error -> Error (Keeper_fs.durable_write_error_to_string error)
  in
  let* persisted = load ~session_dir in
  match persisted with
  | Some persisted when equal persisted binding -> Ok ()
  | Some _ -> Error "Codex session changed after durable write"
  | None -> Error "Codex session missing after durable write"
;;
