open Runtime
open Result_syntax

type t = { root : string }

type run_record =
  { session : session
  ; path : string
  }

type run_load_failure =
  { session_id : string
  ; path : string
  ; detail : string
  }

type run_listing =
  { runs : run_record list
  ; failures : run_load_failure list
  }

let sessions_dir store = Filename.concat store.root "sessions"
let session_dir store session_id = Filename.concat (sessions_dir store) session_id

let session_path store session_id =
  Filename.concat (session_dir store session_id) "session.json"
;;

let snapshots_dir store session_id =
  Filename.concat (session_dir store session_id) "snapshots"
;;

let artifacts_dir store session_id =
  Filename.concat (session_dir store session_id) "artifacts"
;;

let raw_traces_dir store session_id =
  Filename.concat (session_dir store session_id) "raw-traces"
;;

let ensure_dir = Fs_result.ensure_dir

let ensure_tree store session_id =
  let* () = ensure_dir store.root in
  let* () = ensure_dir (sessions_dir store) in
  let* () = ensure_dir (session_dir store session_id) in
  let* () = ensure_dir (snapshots_dir store session_id) in
  let* () = ensure_dir (artifacts_dir store session_id) in
  ensure_dir (raw_traces_dir store session_id)
;;

let validate_root root =
  if Filename.is_relative root
  then
    Error
      (Error.Config
         (InvalidConfig
            { field = "session_root"
            ; detail = "runtime session root must be an absolute path"
            }))
  else Ok root
;;

let create ?root () =
  let* resolved =
    match Util.trim_non_empty_opt root with
    | Some value -> Ok value
    | None ->
      Error
        (Error.Config
           (InvalidConfig
              { field = "session_root"
              ; detail =
                  "missing runtime session root; pass an explicit ~root/session_root"
              }))
  in
  let* resolved = validate_root resolved in
  let store = { root = resolved } in
  let* () = ensure_dir resolved in
  let* () = ensure_dir (sessions_dir store) in
  Ok store
;;

let save_text = Fs_result.write_file
let load_text = Fs_result.read_file

let save_session store (session : session) =
  let* () = ensure_tree store session.session_id in
  save_text
    (session_path store session.session_id)
    (session |> session_to_yojson |> Yojson.Safe.pretty_to_string)
;;

let parse_session raw =
  let with_default key value fields =
    if List.mem_assoc key fields then fields else (key, value) :: fields
  in
  let normalize_participant = function
    | `Assoc fields ->
      `Assoc
        (fields
         |> with_default "aliases" (`List [])
         |> with_default "worker_id" `Null
         |> with_default "runtime_actor" `Null
         |> with_default "requested_provider" `Null
         |> with_default "requested_model" `Null
         |> with_default "resolved_provider" `Null
         |> with_default "resolved_model" `Null
         |> with_default "accepted_at" `Null
         |> with_default "ready_at" `Null
         |> with_default "first_progress_at" `Null
         |> with_default "last_progress_at" `Null)
    | json -> json
  in
  let normalize_session = function
    | `Assoc fields ->
      let participants =
        match List.assoc_opt "participants" fields with
        | Some (`List items) -> `List (List.map normalize_participant items)
        | Some value -> value
        | None -> `List []
      in
      `Assoc
        ((fields |> List.remove_assoc "participants") @ [ "participants", participants ])
    | json -> json
  in
  try
    let normalized = Yojson.Safe.from_string raw |> normalize_session in
    session_of_yojson normalized
    |> Result.map_error (fun detail -> Error.Serialization (JsonParseError { detail }))
  with
  | Yojson.Json_error detail -> Error (Error.Serialization (JsonParseError { detail }))
;;

let load_session store session_id =
  let* raw = load_text (session_path store session_id) in
  parse_session raw
;;

let compare_run_record left right =
  match Float.compare left.session.updated_at right.session.updated_at with
  | 0 -> String.compare left.session.session_id right.session.session_id
  | order -> order
;;

let sort_runs runs = List.sort compare_run_record runs

let run_failure store session_id detail =
  { session_id; path = session_path store session_id; detail }
;;

let list_runs store =
  let root = sessions_dir store in
  if not (Sys.file_exists root)
  then Ok { runs = []; failures = [] }
  else
    root
    |> Sys.readdir
    |> Array.to_list
    |> List.sort String.compare
    |> List.fold_left
         (fun acc session_id ->
            let ({ runs; failures } : run_listing) = acc in
            let dir = session_dir store session_id in
            if not (Sys.is_directory dir)
            then acc
            else (
              match load_session store session_id with
              | Ok session ->
                { runs = { session; path = session_path store session_id } :: runs
                ; failures
                }
              | Error err ->
                { runs
                ; failures =
                    run_failure store session_id (Error.to_string err) :: failures
                }))
         ({ runs = []; failures = [] } : run_listing)
    |> fun (listing : run_listing) ->
    Ok
      ({ runs = sort_runs listing.runs
       ; failures =
           List.sort
             (fun (left : run_load_failure) (right : run_load_failure) ->
                String.compare left.session_id right.session_id)
             listing.failures
       }
       : run_listing)
;;
