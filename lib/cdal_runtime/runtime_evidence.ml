open Runtime

let runtime_persist_failure_prefix = "[runtime_persist_failure phase="
let dropped_output_deltas_marker = "[runtime telemetry] dropped_output_deltas="

type telemetry_step =
  { seq : int
  ; ts : float
  ; event_name : string
  ; kind : string
  ; participant : string option
  ; detail : string option
  ; actor : string option
  ; role : string option
  ; provider : string option
  ; model : string option
  ; raw_trace_run_id : string option
  ; stop_reason : string option
  ; artifact_id : string option
  ; artifact_name : string option
  ; artifact_kind : string option
  ; checkpoint_label : string option
  ; outcome : string option
  ; dropped_output_deltas : int option
  ; persistence_failure_phase : string option
  }

type telemetry_report =
  { session_id : string
  ; generated_at : float
  ; step_count : int
  ; event_counts : (string * int) list
  ; event_name_counts : (string * int) list
  ; dropped_output_deltas : int
  ; persistence_failure_count : int
  ; participants_with_dropped_output_deltas : string list
  ; participants_with_persistence_failures : string list
  ; steps : telemetry_step list
  }

type evidence_file =
  { label : string
  ; path : string
  ; size_bytes : int
  ; md5 : string
  }

type evidence_bundle =
  { session_id : string
  ; generated_at : float
  ; files : evidence_file list
  ; missing_files : (string * string) list
  }

type raw_trace_manifest = Sessions.raw_trace_manifest

let now () = Unix.gettimeofday ()

let encode_persist_failure_detail ~phase message =
  Printf.sprintf "%s%s] %s" runtime_persist_failure_prefix phase message
;;

let append_dropped_output_deltas_summary ~summary ~dropped_output_deltas =
  Printf.sprintf "%s\n\n%s%d" summary dropped_output_deltas_marker dropped_output_deltas
;;

let artifact_attached_event (artifact : Runtime.artifact) =
  Artifact_attached
    { artifact_id = artifact.artifact_id
    ; name = artifact.name
    ; kind = artifact.kind
    ; mime_type = artifact.mime_type
    ; path = Option.value ~default:"" artifact.path
    ; size_bytes = artifact.size_bytes
    }
;;

let base_evidence_file_specs store session_id =
  [ "session_json", Runtime_store.session_path store session_id
  ; "events_jsonl", Runtime_store.events_path store session_id
  ; "report_json", Runtime_store.report_json_path store session_id
  ; "report_md", Runtime_store.report_md_path store session_id
  ; "proof_json", Runtime_store.proof_json_path store session_id
  ; "proof_md", Runtime_store.proof_md_path store session_id
  ]
;;

let find_last_substring_index ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if idx < 0
    then None
    else if String.sub haystack idx needle_len = needle
    then Some idx
    else loop (idx - 1)
  in
  if needle_len = 0 || haystack_len < needle_len
  then None
  else loop (haystack_len - needle_len)
;;

let dropped_output_deltas_of_text = function
  | None -> None
  | Some text ->
    let text = String.trim text in
    (match find_last_substring_index ~needle:dropped_output_deltas_marker text with
     | None -> None
     | Some idx ->
       let start = idx + String.length dropped_output_deltas_marker in
       if start >= String.length text
       then None
       else (
         let raw = String.sub text start (String.length text - start) |> String.trim in
         match int_of_string_opt raw with
         | Some n when n > 0 -> Some n
         | _ -> None))
;;

let persistence_failure_phase_of_text = function
  | None -> None
  | Some text ->
    let text = String.trim text in
    if not (String.starts_with ~prefix:runtime_persist_failure_prefix text)
    then None
    else (
      let start = String.length runtime_persist_failure_prefix in
      match String.index_from_opt text start ']' with
      | None -> None
      | Some stop when stop > start -> Some (String.sub text start (stop - start))
      | Some _ -> None)
;;

let failure_cause_message = function
  | Runtime.Execution_error detail -> detail
  | Runtime.Persistence_failure { phase; detail } -> Printf.sprintf "%s: %s" phase detail
;;

let failure_detail_of_event (detail : Runtime.participant_event) =
  match detail.error, detail.failure_cause with
  | Some error, _ -> Some error
  | None, Some cause -> Some (failure_cause_message cause)
  | None, None -> None
;;

let participant_and_detail_of_event = function
  | Session_started _ -> None, Some "session_started"
  | Session_settings_updated _ -> None, Some "session_settings_updated"
  | Turn_recorded detail -> detail.actor, Some detail.message
  | Agent_spawn_requested detail -> Some detail.participant_name, Some detail.prompt
  | Agent_became_live detail -> Some detail.participant_name, detail.summary
  | Agent_output_delta detail -> Some detail.participant_name, Some detail.delta
  | Agent_completed detail -> Some detail.participant_name, detail.summary
  | Agent_failed detail -> Some detail.participant_name, failure_detail_of_event detail
  | Artifact_attached detail -> None, Some (detail.name ^ ":" ^ detail.kind)
  | Checkpoint_saved detail -> None, detail.label
  | Finalize_requested detail -> None, detail.reason
  | Session_completed detail -> None, detail.outcome
  | Session_failed detail -> None, detail.outcome
;;

let anomaly_fields_of_event = function
  | Agent_completed detail ->
    let dropped_output_deltas =
      match detail.completion_anomaly with
      | Some (Runtime.Dropped_output_deltas { count }) when count > 0 -> Some count
      | Some _ | None -> dropped_output_deltas_of_text detail.summary
    in
    dropped_output_deltas, None
  | Agent_failed detail ->
    let persistence_failure_phase =
      match detail.failure_cause with
      | Some (Runtime.Persistence_failure { phase; _ }) -> Some phase
      | Some _ | None ->
        persistence_failure_phase_of_text (failure_detail_of_event detail)
    in
    None, persistence_failure_phase
  | _ -> None, None
;;

let event_name_of_kind = function
  | Session_started _ -> "session_started"
  | Session_settings_updated _ -> "session_settings_updated"
  | Turn_recorded _ -> "turn_recorded"
  | Agent_spawn_requested _ -> "agent_spawn_requested"
  | Agent_became_live _ -> "agent_became_live"
  | Agent_output_delta _ -> "agent_output_delta"
  | Agent_completed _ -> "agent_completed"
  | Agent_failed _ -> "agent_failed"
  | Artifact_attached _ -> "artifact_attached"
  | Checkpoint_saved _ -> "checkpoint_saved"
  | Finalize_requested _ -> "finalize_requested"
  | Session_completed _ -> "session_completed"
  | Session_failed _ -> "session_failed"
;;

let structured_fields_of_event = function
  | Session_started _ -> None, None, None, None, None, None, None, None, None, None, None
  | Session_settings_updated detail ->
    None, None, None, detail.model, None, None, None, None, None, None, None
  | Turn_recorded detail ->
    detail.actor, None, None, None, None, None, None, None, None, None, None
  | Agent_spawn_requested detail ->
    ( None
    , detail.role
    , detail.provider
    , detail.model
    , None
    , None
    , None
    , None
    , None
    , None
    , None )
  | Agent_became_live detail ->
    ( None
    , None
    , detail.provider
    , detail.model
    , detail.raw_trace_run_id
    , detail.stop_reason
    , None
    , None
    , None
    , None
    , None )
  | Agent_output_delta _ ->
    None, None, None, None, None, None, None, None, None, None, None
  | Agent_completed detail ->
    ( None
    , None
    , detail.provider
    , detail.model
    , detail.raw_trace_run_id
    , detail.stop_reason
    , None
    , None
    , None
    , None
    , None )
  | Agent_failed detail ->
    ( None
    , None
    , detail.provider
    , detail.model
    , detail.raw_trace_run_id
    , detail.stop_reason
    , None
    , None
    , None
    , None
    , None )
  | Artifact_attached detail ->
    ( None
    , None
    , None
    , None
    , None
    , None
    , Some detail.artifact_id
    , Some detail.name
    , Some detail.kind
    , None
    , None )
  | Checkpoint_saved detail ->
    None, None, None, None, None, None, None, None, None, detail.label, None
  | Finalize_requested _ ->
    None, None, None, None, None, None, None, None, None, None, None
  | Session_completed detail ->
    None, None, None, None, None, None, None, None, None, None, detail.outcome
  | Session_failed detail ->
    None, None, None, None, None, None, None, None, None, None, detail.outcome
;;

let build_telemetry_report (session : session) (events : event list) =
  let event_counts =
    List.fold_left
      (fun acc (event : event) ->
         let key = show_event_kind event.kind in
         let prev = Option.value (List.assoc_opt key acc) ~default:0 in
         (key, prev + 1) :: List.remove_assoc key acc)
      []
      events
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  in
  let event_name_counts =
    List.fold_left
      (fun acc (event : event) ->
         let key = event_name_of_kind event.kind in
         let prev = Option.value (List.assoc_opt key acc) ~default:0 in
         (key, prev + 1) :: List.remove_assoc key acc)
      []
      events
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  in
  let steps =
    List.map
      (fun (event : event) ->
         let participant, detail = participant_and_detail_of_event event.kind in
         let ( actor
             , role
             , provider
             , model
             , raw_trace_run_id
             , stop_reason
             , artifact_id
             , artifact_name
             , artifact_kind
             , checkpoint_label
             , outcome )
           =
           structured_fields_of_event event.kind
         in
         let dropped_output_deltas, persistence_failure_phase =
           anomaly_fields_of_event event.kind
         in
         { seq = event.seq
         ; ts = event.ts
         ; event_name = event_name_of_kind event.kind
         ; kind = show_event_kind event.kind
         ; participant
         ; detail
         ; actor
         ; role
         ; provider
         ; model
         ; raw_trace_run_id
         ; stop_reason
         ; artifact_id
         ; artifact_name
         ; artifact_kind
         ; checkpoint_label
         ; outcome
         ; dropped_output_deltas
         ; persistence_failure_phase
         })
      events
  in
  let dropped_output_deltas =
    List.fold_left
      (fun acc (step : telemetry_step) ->
         acc + Option.value step.dropped_output_deltas ~default:0)
      0
      steps
  in
  let participants_with_dropped_output_deltas =
    steps
    |> List.filter_map (fun (step : telemetry_step) ->
      match step.participant, step.dropped_output_deltas with
      | Some participant, Some n when n > 0 -> Some participant
      | _ -> None)
    |> List.sort_uniq String.compare
  in
  let participants_with_persistence_failures =
    steps
    |> List.filter_map (fun (step : telemetry_step) ->
      match step.participant, step.persistence_failure_phase with
      | Some participant, Some _ -> Some participant
      | _ -> None)
    |> List.sort_uniq String.compare
  in
  let persistence_failure_count =
    List.fold_left
      (fun acc (step : telemetry_step) ->
         match step.persistence_failure_phase with
         | Some _ -> acc + 1
         | None -> acc)
      0
      steps
  in
  { session_id = session.session_id
  ; generated_at = now ()
  ; step_count = List.length steps
  ; event_counts
  ; event_name_counts
  ; dropped_output_deltas
  ; persistence_failure_count
  ; participants_with_dropped_output_deltas
  ; participants_with_persistence_failures
  ; steps
  }
;;

let telemetry_report_to_json (report : telemetry_report) =
  `Assoc
    [ "session_id", `String report.session_id
    ; "generated_at", `Float report.generated_at
    ; "step_count", `Int report.step_count
    ; "dropped_output_deltas", `Int report.dropped_output_deltas
    ; "persistence_failure_count", `Int report.persistence_failure_count
    ; ( "participants_with_dropped_output_deltas"
      , `List
          (List.map
             (fun participant -> `String participant)
             report.participants_with_dropped_output_deltas) )
    ; ( "participants_with_persistence_failures"
      , `List
          (List.map
             (fun participant -> `String participant)
             report.participants_with_persistence_failures) )
    ; ( "event_counts"
      , `Assoc (List.map (fun (name, count) -> name, `Int count) report.event_counts) )
    ; ( "event_name_counts"
      , `List
          (List.map
             (fun (event_name, count) ->
                `Assoc [ "event_name", `String event_name; "count", `Int count ])
             report.event_name_counts) )
    ; ( "steps"
      , `List
          (List.map
             (fun step ->
                `Assoc
                  [ "seq", `Int step.seq
                  ; "ts", `Float step.ts
                  ; "event_name", `String step.event_name
                  ; "kind", `String step.kind
                  ; ( "participant"
                    , match step.participant with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "detail"
                    , match step.detail with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "actor"
                    , match step.actor with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "role"
                    , match step.role with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "provider"
                    , match step.provider with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "model"
                    , match step.model with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "raw_trace_run_id"
                    , match step.raw_trace_run_id with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "stop_reason"
                    , match step.stop_reason with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "artifact_id"
                    , match step.artifact_id with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "artifact_name"
                    , match step.artifact_name with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "artifact_kind"
                    , match step.artifact_kind with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "checkpoint_label"
                    , match step.checkpoint_label with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "outcome"
                    , match step.outcome with
                      | Some value -> `String value
                      | None -> `Null )
                  ; ( "dropped_output_deltas"
                    , match step.dropped_output_deltas with
                      | Some value -> `Int value
                      | None -> `Null )
                  ; ( "persistence_failure_phase"
                    , match step.persistence_failure_phase with
                      | Some value -> `String value
                      | None -> `Null )
                  ])
             report.steps) )
    ]
;;

let telemetry_report_to_markdown (report : telemetry_report) =
  let counts =
    report.event_counts
    |> List.map (fun (name, count) -> Printf.sprintf "- %s: %d" name count)
    |> String.concat "\n"
  in
  let steps =
    report.steps
    |> List.map (fun step ->
      let participant =
        match step.participant with
        | Some value -> value
        | None -> "-"
      in
      let detail =
        match step.detail with
        | Some value when String.trim value <> "" -> value
        | _ -> "-"
      in
      let anomalies =
        [ (match step.dropped_output_deltas with
           | Some count -> Some (Printf.sprintf " dropped_output_deltas=%d" count)
           | None -> None)
        ; (match step.persistence_failure_phase with
           | Some phase -> Some (Printf.sprintf " persistence_failure_phase=%s" phase)
           | None -> None)
        ]
        |> List.filter_map (fun item -> item)
        |> String.concat ""
      in
      Printf.sprintf
        "- #%d %s participant=%s detail=%s%s"
        step.seq
        step.kind
        participant
        detail
        anomalies)
    |> String.concat "\n"
  in
  let anomaly_lines =
    [ Printf.sprintf "- Dropped Output Deltas: %d" report.dropped_output_deltas
    ; Printf.sprintf "- Persistence Failures: %d" report.persistence_failure_count
    ]
    @ (report.participants_with_dropped_output_deltas
       |> List.map (fun participant ->
         Printf.sprintf "- dropped_output_deltas participant=%s" participant))
    @ (report.participants_with_persistence_failures
       |> List.map (fun participant ->
         Printf.sprintf "- persistence_failure participant=%s" participant))
  in
  String.concat
    "\n"
    [ "# Runtime Telemetry"
    ; ""
    ; Printf.sprintf "- Session ID: %s" report.session_id
    ; Printf.sprintf "- Step Count: %d" report.step_count
    ; ""
    ; "## Anomalies"
    ; String.concat "\n" anomaly_lines
    ; ""
    ; "## Event Name Counts"
    ; report.event_name_counts
      |> List.map (fun (name, count) -> Printf.sprintf "- %s: %d" name count)
      |> String.concat "\n"
    ; ""
    ; "## Event Counts"
    ; counts
    ; ""
    ; "## Steps"
    ; steps
    ; ""
    ]
;;

let digest_file_md5 path = Digest.file path |> Digest.to_hex
let file_size path = (Unix.stat path).st_size

let build_evidence_bundle ~session_id file_specs =
  let files, missing_files =
    List.fold_left
      (fun (files, missing_files) (label, path) ->
         if Sys.file_exists path
         then
           ( { label; path; size_bytes = file_size path; md5 = digest_file_md5 path }
             :: files
           , missing_files )
         else files, (label, path) :: missing_files)
      ([], [])
      file_specs
  in
  { session_id
  ; generated_at = now ()
  ; files = List.rev files
  ; missing_files = List.rev missing_files
  }
;;

let build_raw_trace_manifest
      ~session_id
      ~latest_raw_trace_run
      ~raw_trace_runs
      ~raw_trace_summaries
      ~raw_trace_validations
  =
  ({ session_id
   ; generated_at = now ()
   ; latest_raw_trace_run
   ; raw_trace_runs
   ; raw_trace_summaries
   ; raw_trace_validations
   }
   : Sessions.raw_trace_manifest)
;;

let evidence_bundle_to_json (bundle : evidence_bundle) =
  `Assoc
    [ "session_id", `String bundle.session_id
    ; "generated_at", `Float bundle.generated_at
    ; ( "files"
      , `List
          (List.map
             (fun file ->
                `Assoc
                  [ "label", `String file.label
                  ; "path", `String file.path
                  ; "size_bytes", `Int file.size_bytes
                  ; "md5", `String file.md5
                  ])
             bundle.files) )
    ; ( "missing_files"
      , `List
          (List.map
             (fun (label, path) ->
                `Assoc [ "label", `String label; "path", `String path ])
             bundle.missing_files) )
    ]
;;

let raw_trace_manifest_to_json (manifest : raw_trace_manifest) =
  Sessions.raw_trace_manifest_to_yojson manifest
;;
