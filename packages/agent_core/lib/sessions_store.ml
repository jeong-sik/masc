(** Sessions store operations — file I/O, artifact retrieval, raw trace access.

    Read-from-store operations that bridge the runtime file layout
    with the typed Sessions domain. JSON parsing lives in
    {!Sessions_store_parsers}. *)

open Sessions_types
open Sessions_store_parsers
open Result_syntax

let make_store ?session_root () = Runtime_store.create ?root:session_root ()
let file_read_error = Util.file_read_error
let first_some = Util.first_some

(** [result_all xs] collects a list of results into a result of a list,
    short-circuiting on the first [Error] and preserving element order. *)
let result_all xs =
  List.fold_left
    (fun acc item ->
       let* acc = acc in
       let* item = item in
       Ok (item :: acc))
    (Ok [])
    xs
  |> Result.map List.rev
;;

let primary_alias aliases =
  match aliases with
  | alias :: _ when String.trim alias <> "" -> Some alias
  | [] -> None
  | _blank_alias :: _ -> None
;;

let latest_named_artifact artifacts name =
  List.fold_left
    (fun acc (artifact : Runtime.artifact) ->
       if not (String.equal artifact.name name)
       then acc
       else (
         match acc with
         | None -> Some artifact
         | Some current when artifact.created_at >= current.created_at -> Some artifact
         | Some _ -> acc))
    None
    artifacts
;;

let get_named_artifact ?session_root ~session_id ~name () =
  let* artifacts = Artifact_service.list ?session_root ~session_id () in
  match latest_named_artifact artifacts name with
  | Some artifact -> Ok artifact
  | None ->
    Error
      (file_read_error
         ~path:name
         ~detail:(Printf.sprintf "Artifact '%s' not found in session %s" name session_id))
;;

let get_raw_trace_dir ?session_root ~session_id () =
  let* store = make_store ?session_root () in
  Ok (Runtime_store.raw_traces_dir store session_id)
;;

let get_raw_trace_files ?session_root ~session_id () =
  let* dir = get_raw_trace_dir ?session_root ~session_id () in
  if not (Sys.file_exists dir)
  then Ok []
  else
    dir
    |> Sys.readdir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
    |> List.sort String.compare
    |> List.map (fun name -> Filename.concat dir name)
    |> fun paths -> Ok paths
;;

let get_report ?session_root ~session_id () =
  let* store = make_store ?session_root () in
  let path = Runtime_store.report_json_path store session_id in
  let* raw = Runtime_store.load_text path in
  parse_runtime_json Runtime.report_of_yojson raw
;;

let get_proof ?session_root ~session_id () =
  let* store = make_store ?session_root () in
  let path = Runtime_store.proof_json_path store session_id in
  let* raw = Runtime_store.load_text path in
  parse_runtime_json Runtime.proof_of_yojson raw
;;

let list_sessions ?session_root () =
  let* store = make_store ?session_root () in
  let root = Runtime_store.sessions_dir store in
  if not (Sys.file_exists root)
  then Ok []
  else
    root
    |> Sys.readdir
    |> Array.to_list
    |> List.sort String.compare
    |> List.fold_left
         (fun acc session_id ->
            let* rev = acc in
            let path = Runtime_store.session_path store session_id in
            if Sys.is_directory (Runtime_store.session_dir store session_id)
            then (
              match Runtime_store.load_session store session_id with
              | Ok session ->
                Ok
                  ({ session_id = session.session_id
                   ; title = session.title
                   ; tag = session.tag
                   ; goal = session.goal
                   ; updated_at = session.updated_at
                   ; phase = session.phase
                   ; participant_count = List.length session.participants
                   ; path
                   }
                   :: rev)
              | Error _ -> Ok rev)
            else Ok rev)
         (Ok [])
    |> Result.map List.rev
;;

let get_session ?session_root session_id =
  let* store = make_store ?session_root () in
  Runtime_store.load_session store session_id
;;

let get_telemetry ?session_root ~session_id () =
  let* artifact =
    get_named_artifact ?session_root ~session_id ~name:"runtime-telemetry-json" ()
  in
  let* raw =
    Artifact_service.get_text
      ?session_root
      ~session_id
      ~artifact_id:artifact.artifact_id
      ()
  in
  decode_json_with telemetry_of_json raw
;;

let get_telemetry_structured ?session_root ~session_id () =
  let* artifact =
    get_named_artifact ?session_root ~session_id ~name:"runtime-telemetry-json" ()
  in
  let* raw =
    Artifact_service.get_text
      ?session_root
      ~session_id
      ~artifact_id:artifact.artifact_id
      ()
  in
  decode_json_with structured_telemetry_of_json raw
;;

let get_evidence ?session_root ~session_id () =
  let* artifact =
    get_named_artifact ?session_root ~session_id ~name:"runtime-evidence" ()
  in
  let* raw =
    Artifact_service.get_text
      ?session_root
      ~session_id
      ~artifact_id:artifact.artifact_id
      ()
  in
  decode_json_with evidence_of_json raw
;;

let get_raw_trace_manifest ?session_root ~session_id () =
  let* artifact =
    get_named_artifact ?session_root ~session_id ~name:"runtime-raw-trace-json" ()
  in
  let* raw =
    Artifact_service.get_text
      ?session_root
      ~session_id
      ~artifact_id:artifact.artifact_id
      ()
  in
  parse_runtime_json raw_trace_manifest_of_json raw
;;

let get_raw_trace_runs ?session_root ~session_id () =
  let* paths = get_raw_trace_files ?session_root ~session_id () in
  let+ runs =
    paths
    |> List.map (fun path -> Raw_trace_query.read_runs ~path ())
    |> result_all
    |> Result.map List.flatten
  in
  List.sort
    (fun (a : raw_trace_run) (b : raw_trace_run) -> Int.compare a.start_seq b.start_seq)
    runs
;;

let get_raw_trace_run ?session_root ~session_id ~worker_run_id () =
  let* runs = get_raw_trace_runs ?session_root ~session_id () in
  match
    List.find_opt
      (fun (run : raw_trace_run) -> String.equal run.worker_run_id worker_run_id)
      runs
  with
  | Some run -> Ok run
  | None ->
    Error
      (file_read_error
         ~path:worker_run_id
         ~detail:
           (Printf.sprintf
              "Raw trace run '%s' not found in session %s"
              worker_run_id
              session_id))
;;

let get_raw_trace_records ?session_root ~session_id ~worker_run_id () =
  let* run = get_raw_trace_run ?session_root ~session_id ~worker_run_id () in
  Raw_trace_query.read_run run
;;

let get_raw_trace_summary ?session_root ~session_id ~worker_run_id () =
  let* run = get_raw_trace_run ?session_root ~session_id ~worker_run_id () in
  Raw_trace_query.summarize_run run
;;

let validate_raw_trace_run ?session_root ~session_id ~worker_run_id () =
  let* run = get_raw_trace_run ?session_root ~session_id ~worker_run_id () in
  Raw_trace_query.validate_run run
;;

let get_latest_raw_trace_run ?session_root ~session_id () =
  let* runs = get_raw_trace_runs ?session_root ~session_id () in
  match List.rev runs with
  | latest :: _ -> Ok (Some latest)
  | [] -> Ok None
;;

let summarize_runs runs = runs |> List.map Raw_trace_query.summarize_run |> result_all

let get_raw_trace_summaries ?session_root ~session_id () =
  let* runs = get_raw_trace_runs ?session_root ~session_id () in
  summarize_runs runs
;;

let validate_runs runs = runs |> List.map Raw_trace_query.validate_run |> result_all

let get_raw_trace_validations ?session_root ~session_id () =
  let* runs = get_raw_trace_runs ?session_root ~session_id () in
  validate_runs runs
;;
