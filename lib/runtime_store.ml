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

type run_window =
  | Last_n_runs of int
  | Session of string
  | Rolling_seconds of float

type run_event_record =
  { event_id : string
  ; session_id : string
  ; event : event
  }

type run_window_events =
  { runs : run_record list
  ; events : run_event_record list
  ; failures : run_load_failure list
  }

let sessions_dir store = Filename.concat store.root "sessions"
let session_dir store session_id = Filename.concat (sessions_dir store) session_id

let session_path store session_id =
  Filename.concat (session_dir store session_id) "session.json"
;;

let events_path store session_id =
  Filename.concat (session_dir store session_id) "events.jsonl"
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

let report_json_path store session_id =
  Filename.concat (artifacts_dir store session_id) "report.json"
;;

let report_md_path store session_id =
  Filename.concat (artifacts_dir store session_id) "report.md"
;;

let proof_json_path store session_id =
  Filename.concat (artifacts_dir store session_id) "proof.json"
;;

let proof_md_path store session_id =
  Filename.concat (artifacts_dir store session_id) "proof.md"
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

let take n xs =
  if n <= 0
  then []
  else (
    let rec loop remaining acc = function
      | [] -> List.rev acc
      | _ when remaining <= 0 -> List.rev acc
      | x :: rest -> loop (remaining - 1) (x :: acc) rest
    in
    loop n [] xs)
;;

let select_from_listing store (listing : run_listing) = function
  | Last_n_runs n -> listing.runs |> List.rev |> take n |> sort_runs, []
  | Session session_id ->
    (match
       List.find_opt
         (fun run -> String.equal run.session.session_id session_id)
         listing.runs
     with
     | Some run -> [ run ], []
     | None ->
       if
         List.exists
           (fun (failure : run_load_failure) ->
              String.equal failure.session_id session_id)
           listing.failures
       then [], []
       else
         ( []
         , [ run_failure
               store
               session_id
               (Printf.sprintf "session %S not found in runtime store" session_id)
           ] ))
  | Rolling_seconds seconds ->
    if seconds <= 0.0
    then [], []
    else (
      match List.rev listing.runs with
      | [] -> [], []
      | newest :: _ ->
        let lower_bound = newest.session.updated_at -. seconds in
        List.filter (fun run -> run.session.updated_at >= lower_bound) listing.runs, [])
;;

let dedupe_runs runs =
  let seen = Hashtbl.create (List.length runs) in
  runs
  |> List.filter (fun run ->
    let session_id = run.session.session_id in
    if Hashtbl.mem seen session_id
    then false
    else (
      Hashtbl.replace seen session_id ();
      true))
  |> sort_runs
;;

let dedupe_failures failures =
  let seen = Hashtbl.create (List.length failures) in
  failures
  |> List.filter (fun (failure : run_load_failure) ->
    let key = failure.session_id ^ "\x00" ^ failure.path ^ "\x00" ^ failure.detail in
    if Hashtbl.mem seen key
    then false
    else (
      Hashtbl.replace seen key ();
      true))
  |> List.sort (fun (left : run_load_failure) (right : run_load_failure) ->
    match String.compare left.session_id right.session_id with
    | 0 -> String.compare left.detail right.detail
    | order -> order)
;;

let select_run_windows store windows =
  let* listing = list_runs store in
  let selected, window_failures =
    List.fold_left
      (fun (runs, failures) window ->
         let window_runs, new_failures = select_from_listing store listing window in
         window_runs @ runs, new_failures @ failures)
      ([], [])
      windows
  in
  Ok
    ({ runs = dedupe_runs selected
     ; failures = dedupe_failures (listing.failures @ window_failures)
     }
     : run_listing)
;;

let append_event store session_id (event : event) =
  let* () = ensure_tree store session_id in
  let path = events_path store session_id in
  let line = (event |> event_to_yojson |> Yojson.Safe.to_string) ^ "\n" in
  Fs_result.append_file path line
;;

let read_events store session_id ?after_seq () =
  let path = events_path store session_id in
  if not (Sys.file_exists path)
  then Ok []
  else (
    let parse_event_line line =
      try
        event_of_yojson (Yojson.Safe.from_string line)
        |> Result.map_error (fun detail ->
          Error.Serialization (JsonParseError { detail }))
      with
      | Yojson.Json_error detail ->
        Error (Error.Serialization (JsonParseError { detail }))
    in
    let* raw = load_text path in
    raw
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> Util.filter_non_empty
    |> List.fold_left
         (fun acc line ->
            let* rev = acc in
            let* event = parse_event_line line in
            let should_include =
              match after_seq with
              | Some min_seq -> event.seq > min_seq
              | None -> true
            in
            Ok (if should_include then event :: rev else rev))
         (Ok [])
    |> Result.map List.rev)
;;

let run_event_id session_id (event : event) = Printf.sprintf "%s#%d" session_id event.seq

let read_window_events store windows =
  let* listing = select_run_windows store windows in
  let event_seen = Hashtbl.create 64 in
  let run_order = Hashtbl.create (List.length listing.runs) in
  List.iteri
    (fun index run -> Hashtbl.replace run_order run.session.session_id index)
    listing.runs;
  let events, event_failures =
    List.fold_left
      (fun (events, failures) run ->
         let session_id = run.session.session_id in
         match read_events store session_id () with
         | Error err ->
           events, run_failure store session_id (Error.to_string err) :: failures
         | Ok loaded ->
           let new_events =
             loaded
             |> List.filter_map (fun event ->
               let event_id = run_event_id session_id event in
               if Hashtbl.mem event_seen event_id
               then None
               else (
                 Hashtbl.replace event_seen event_id ();
                 Some { event_id; session_id; event }))
           in
           new_events @ events, failures)
      ([], [])
      listing.runs
  in
  Ok
    ({ runs = listing.runs
     ; events =
         List.sort
           (fun left right ->
              match
                Int.compare
                  (Option.value
                     (Hashtbl.find_opt run_order left.session_id)
                     ~default:max_int)
                  (Option.value
                     (Hashtbl.find_opt run_order right.session_id)
                     ~default:max_int)
              with
              | 0 -> Int.compare left.event.seq right.event.seq
              | order -> order)
           events
     ; failures = dedupe_failures (listing.failures @ event_failures)
     }
     : run_window_events)
;;

let snapshot_path store session_id ~seq ~label =
  let base =
    match label with
    | Some value when String.trim value <> "" ->
      Printf.sprintf
        "%04d-%s.json"
        seq
        (String.map
           (function
             | '/' | ' ' -> '_'
             | c -> c)
           value)
    | Some _ | None -> Printf.sprintf "%04d.json" seq
  in
  Filename.concat (snapshots_dir store session_id) base
;;

let save_snapshot store (session : session) ~label =
  let path = snapshot_path store session.session_id ~seq:session.last_seq ~label in
  let* () = ensure_tree store session.session_id in
  let* () =
    save_text path (session |> session_to_yojson |> Yojson.Safe.pretty_to_string)
  in
  Ok path
;;

let save_artifact_text store session_id ~name ~kind ~content =
  let safe_name =
    if String.trim name = ""
    then "artifact"
    else
      String.map
        (function
          | '/' | ' ' -> '_'
          | c -> c)
        name
  in
  let extension =
    let normalized = String.lowercase_ascii kind in
    if normalized = ""
    then "txt"
    else (
      match normalized with
      | "markdown" | "md" -> "md"
      | "json" -> "json"
      | "text" | "txt" -> "txt"
      | other -> other)
  in
  let path =
    Filename.concat
      (artifacts_dir store session_id)
      (Printf.sprintf "%s.%s" safe_name extension)
  in
  let* () = ensure_tree store session_id in
  let* () = save_text path content in
  Ok path
;;

let save_report store (report : report) =
  let* () = ensure_tree store report.session_id in
  let* () =
    save_text
      (report_json_path store report.session_id)
      (report |> report_to_yojson |> Yojson.Safe.pretty_to_string)
  in
  save_text (report_md_path store report.session_id) report.markdown
;;

let save_proof store (proof : proof) =
  let* () = ensure_tree store proof.session_id in
  let* () =
    save_text
      (proof_json_path store proof.session_id)
      (proof |> proof_to_yojson |> Yojson.Safe.pretty_to_string)
  in
  let markdown =
    let checks =
      proof.checks
      |> List.map (fun check ->
        Printf.sprintf "- [%s] %s" (if check.passed then "x" else " ") check.name)
      |> String.concat "\n"
    in
    let evidence =
      proof.evidence |> List.map (fun line -> "- " ^ line) |> String.concat "\n"
    in
    String.concat
      "\n"
      [ "# Runtime Proof"
      ; ""
      ; Printf.sprintf "- Session ID: %s" proof.session_id
      ; Printf.sprintf "- Overall OK: %b" proof.ok
      ; ""
      ; "## Checks"
      ; checks
      ; ""
      ; "## Evidence"
      ; evidence
      ; ""
      ]
  in
  save_text (proof_md_path store proof.session_id) markdown
;;
