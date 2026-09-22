(** Explicit synthetic continuity measurement. The report file is authoritative;
    an optional content-addressed blob is a copy subject to blob retention. *)
module R = Masc.Librarian_continuity_report
module T = Agent_core.Types

let ( let* ) = Result.bind
let ( let+ ) value f = Result.map f value

type options =
  { input_path : string
  ; output_path : string
  ; config_path : string
  ; runtime_id : string
  ; publish_base_path : string option
  }

let usage =
  "masc-librarian-continuity --input DATASET.json --output REPORT.json \
   --config runtime.toml --runtime EXACT_ID [--publish-base-path DIR]\n\n\
   Storage experiments: masc-librarian-continuity capture --help | restore --help"

let parse_options ?(start = 0) () =
  let input = ref None and output = ref None and config = ref None in
  let runtime = ref None and publish = ref None in
  let set target value = target := Some value in
  Arg.parse_argv ~current:(ref start) Sys.argv
    [ "--input", Arg.String (set input), "Explicit synthetic dataset JSON"
    ; "--output", Arg.String (set output), "Authoritative report JSON"
    ; "--config", Arg.String (set config), "Runtime TOML configuration"
    ; "--runtime", Arg.String (set runtime), "Exact Agent Core runtime ID"
    ; "--publish-base-path", Arg.String (set publish), "Publish a blob copy under this base path"
    ]
    (fun argument -> raise (Arg.Bad ("Unexpected argument: " ^ argument)))
    usage;
  let required name = function
    | Some value when String.trim value <> "" -> Ok value
    | None | Some _ -> Error ("Missing or empty " ^ name)
  in
  let* input_path = required "--input" !input in
  let* output_path = required "--output" !output in
  let* config_path = required "--config" !config in
  let* runtime_id = required "--runtime" !runtime in
  Ok
    { input_path = Config_dir_resolver.absolute_path input_path
    ; output_path = Config_dir_resolver.absolute_path output_path
    ; config_path = Config_dir_resolver.absolute_path config_path
    ; runtime_id
    ; publish_base_path = Option.map Config_dir_resolver.absolute_path !publish
    }

let read_dataset_with parse path =
  try
    let bytes = In_channel.with_open_bin path In_channel.input_all in
    let+ dataset = parse (Yojson.Safe.from_string bytes) in
    bytes, dataset
  with
  | Sys_error detail | Yojson.Json_error detail -> Error detail

let read_dataset path = read_dataset_with R.parse_dataset path

let check_output options =
  if String.equal options.input_path options.output_path then
    Error "--output must differ from --input"
  else
    match Fs_compat.exact_path_kind ~follow:false options.output_path with
    | Fs_compat.Exact_missing -> Ok ()
    | Fs_compat.Exact_kind _ -> Error ("Output already exists: " ^ options.output_path)
    | Fs_compat.Exact_unknown -> Error ("Cannot inspect output path: " ^ options.output_path)

let prepare_runtime options =
  let* observation =
    try
      let (_ : string option) =
        Server_runtime_bootstrap.configure_agent_core_model_catalog_env ()
      in
      Runtime.load_config_observation ~runtime_config_path:options.config_path ()
    with Env_config_core.Config_error detail -> Error detail
  in
  let* outcome =
    Runtime.init_default_degraded_observation observation
    |> Result.map_error Runtime.strict_init_error_to_string
  in
  (match outcome with
   | Runtime.Initialized -> ()
   | Runtime.Initialized_degraded degradation ->
       Log.Runtime.warn "librarian-continuity startup degradation: %s"
         (Yojson.Safe.to_string (Runtime.startup_degradation_to_yojson (Some degradation))));
  let* provider_cfg =
    match Runtime.get_runtime_by_id options.runtime_id with
    | None -> Error ("Configured runtime not found: " ^ options.runtime_id)
    | Some runtime ->
        (match runtime.execution with
         | Runtime_execution.Claude_code _
         | Runtime_execution.Codex_app_server _
         | Runtime_execution.Antigravity_cli _ ->
             Error "Continuity measurement requires an Agent Core runtime; CLI transports are unsupported"
         | Runtime_execution.Agent_core _ ->
             let* providers =
               Runtime_agent_core_runner.resolve_runtime_providers_for_turn
                 ~runtime_id:options.runtime_id ()
             in
             match providers with
             | [ provider ] -> Ok provider
             | [] | _ :: _ -> Error "An exact runtime ID must resolve to one provider")
  in
  Ok (Runtime.config_source_revision_to_string observation.source_revision, provider_cfg)

let runtime_stop = function
  | Runtime_agent.Completed -> "completed"
  | Runtime_agent.Yielded_to_operation_queued _ -> "operation_queued"
  | Runtime_agent.Yielded_to_durable_stimulus _ -> "durable_stimulus"
  | Runtime_agent.Yielded_after_repeated_tool_call _ -> "repeated_tool_call"
  | Runtime_agent.Yielded_after_repeated_assistant_text _ -> "repeated_assistant_text"
  | Runtime_agent.InputRequired _ -> "input_required"

let generate ~sw ~net ~runtime_id ~provider_cfg (prompt : R.prompt) =
  let prepared = ref [] in
  let observe observation =
    (* Constant work at the pre-dispatch boundary; no I/O or artificial cap.
       These bytes were prepared, not proven to have reached the provider. *)
    prepared := observation :: !prepared;
    Ok ()
  in
  let config =
    { (Runtime_agent.default_config ~name:"librarian-continuity"
         ~provider_cfg ~system_prompt:prompt.system ~tools:[]) with
      runtime_id = Some runtime_id
    ; initial_messages = []
    ; pre_dispatch_serialization_observer = Some observe
    }
  in
  let request () : R.generation_request =
    { runtime_id; requested_model = config.model_id; prompt
    ; prepared_requests = List.rev !prepared
    }
  in
  match Runtime_agent.run ~sw ~net ~config prompt.user with
  | Error error ->
      Error
        ({ request = request (); error = Agent_core.Error.to_string error
         ; incomplete_response = None
         } : R.failed_generation)
  | Ok result ->
      let response : R.text_response =
        { response_id = result.response.id
        ; model = result.response.model
        ; text = T.text_of_response result.response
        }
      in
      let complete =
        match result.stop_reason, result.response.stop_reason with
        | Runtime_agent.Completed, (T.EndTurn | T.StopSequence) -> true
        | _ -> false
      in
      if complete && String.trim response.text <> "" then
        Ok ({ request = request (); response } : R.generation)
      else
        Error
          ({ request = request ()
           ; error =
               Printf.sprintf "Generation did not yield completed nonempty text (runtime=%s, response=%s)"
                 (runtime_stop result.stop_reason)
                 (T.stop_reason_to_string result.response.stop_reason)
           ; incomplete_response = Some response
           } : R.failed_generation)

let judge ~clock ~endpoint (request : R.judge_request) =
  let* api_key =
    match Masc.Typesafeai_config.api_key () with
    | None -> Error "TypeSafe API key is not configured"
    | Some api_key ->
        if Masc.Typesafeai_config.is_enabled () then Ok api_key
        else Error "TypeSafe evaluation is disabled by configuration"
  in
  let destination = { Masc.Typesafeai_client.endpoint; model = request.model; api_key } in
  let* evaluated =
    Masc.Typesafeai_client.evaluate ~clock ~destinations:(destination, [])
      ~state:(R.judge_state request) ~questions:(R.judge_questions request) ()
    |> Result.map_error Masc.Typesafeai_client.failure_to_string
  in
  R.judgment request evaluated

let save_report (report : R.t) =
  let bytes = Yojson.Safe.pretty_to_string (R.to_yojson report) ^ "\n" in
  let+ () =
    Masc.Keeper_fs.save_bytes_durable_atomic report.output_path bytes
    |> Result.map_error Masc.Keeper_fs.durable_write_error_to_string
  in
  bytes

let create_report_bytes ~fs ~output_path bytes =
  try
    let directory = Filename.dirname output_path in
    let (_ : string) = Masc.Keeper_fs.ensure_dir directory in
    Eio.Path.with_open_dir Eio.Path.(fs / directory) (fun parent ->
      Fs_compat.create_capability_file_exclusive ~parent
        ~leaf:(Filename.basename output_path) ~permissions:0o600 bytes)
    |> Result.map_error Fs_compat.capability_write_error_to_string
  with
  | Sys_error detail -> Error detail
  | Eio.Io _ as error -> Error (Printexc.to_string error)

let create_report ~fs (report : R.t) =
  let bytes = Yojson.Safe.pretty_to_string (R.to_yojson report) ^ "\n" in
  let+ () = create_report_bytes ~fs ~output_path:report.output_path bytes in
  bytes

let measure_case ~generate ~clock ~save (case : R.case) =
  let question =
    match case.question with
    | Some question -> Ok (R.Provided question)
    | None -> Result.map (fun generation -> R.Generated generation)
        (generate (R.question_prompt case.source))
  in
  match question with
  | Error failed -> save (R.Question_failed failed)
  | Ok question ->
      let* _ = save (R.Question_ready question) in
      let question_text = R.question_text question in
      (match generate (R.answer_prompt ~question:question_text case.context) with
       | Error failed -> save (R.Answer_failed (question, failed))
       | Ok answer ->
           let* _ = save (R.Answer_ready { question; answer }) in
           let endpoint = Masc.Typesafeai_config.endpoint () in
           let request =
             R.judge_request
               ~endpoint:(Masc.Typesafeai_client.endpoint_for_observation endpoint)
               ~model:(Masc.Typesafeai_config.model ()) case
               ~question:question_text ~answer:answer.response.text
           in
           match judge ~clock ~endpoint request with
           | Ok judgment -> save (R.Scored { question; answer; judgment })
           | Error error ->
               save (R.Judge_failed { question; answer; failure = { request; error } }))

let measure ~fs ~generate ~clock (report : R.t) =
  let* initial_bytes = create_report ~fs report in
  let rec loop completed bytes = function
    | [] -> Ok ({ report with samples = List.rev completed }, bytes)
    | (sample : R.sample) :: rest ->
        let save progress =
          let sample = { sample with progress } in
          let snapshot = { report with samples = List.rev_append completed (sample :: rest) } in
          let+ bytes = save_report snapshot in
          sample, bytes
        in
        let* sample, bytes = measure_case ~generate ~clock ~save sample.case in
        loop (sample :: completed) bytes rest
  in
  loop [] initial_bytes report.samples

let scored (sample : R.sample) =
  match sample.progress with
  | R.Scored _ -> true
  | R.Not_started | R.Question_failed _ | R.Question_ready _ | R.Answer_failed _
  | R.Answer_ready _ | R.Judge_failed _ -> false

let publish options report bytes =
  let all_scored = List.for_all scored report.R.samples in
  let published =
    match options.publish_base_path with
    | None -> Ok None
    | Some base_path ->
        (try
           let blob = Tool_blob_store.put_durable
               (Tool_blob_store.create ~base_path) ~bytes ~mime:"application/json" in
           Ok (Some blob.sha256)
         with Sys_error detail -> Error detail)
  in
  let fields =
    [ "output_path", `String options.output_path
    ; "sha256", `String Digestif.SHA256.(to_hex (digest_string bytes))
    ; "all_cases_scored", `Bool all_scored
    ]
  in
  let publication_fields =
    match published with
    | Ok blob ->
        [ "blob_sha256", (match blob with None -> `Null | Some sha -> `String sha) ]
    | Error detail -> [ "blob_sha256", `Null; "publication_error", `String detail ]
  in
  print_endline (Yojson.Safe.to_string (`Assoc (fields @ publication_fields)));
  flush stdout;
  if all_scored then 0 else 1

let run options =
  let* () = check_output options in
  let* input_bytes, dataset = read_dataset options.input_path in
  let* config_revision, provider_cfg = prepare_runtime options in
  let identity = Masc.Build_identity.current () in
  let report : R.t =
    { schema = R.schema
    ; provenance = dataset.provenance
    ; run_id = identity.runtime_instance_id
    ; started_at = identity.started_at
    ; input_path = options.input_path
    ; input_sha256 = Digestif.SHA256.(to_hex (digest_string input_bytes))
    ; output_path = options.output_path
    ; config_revision
    ; binary_commit = identity.binary_commit
    ; executable_sha256 = identity.executable_sha256
    ; samples = List.map (fun case -> { R.case; progress = R.Not_started }) dataset.cases
    }
  in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Eio_context.set_env env;
      Eio_context.set_switch sw;
      Eio_context.set_net (Eio.Stdenv.net env);
      Eio_context.set_clock (Eio.Stdenv.clock env);
      Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
      Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
        let generate = generate ~sw ~net:(Eio.Stdenv.net env)
            ~runtime_id:options.runtime_id ~provider_cfg in
        let+ report, bytes = measure ~fs:(Eio.Stdenv.fs env)
            ~generate ~clock:(Eio.Stdenv.clock env) report in
        publish options report bytes)))

(* Both answer arms share the reference, question, Memory facts and configured
   provider. Only the representation of the covered history changes. *)
let run_comparison options =
  let module M = Masc.Librarian_working_state_evaluation in
  let* () = check_output options in
  let* input_bytes, dataset = read_dataset_with M.parse_dataset options.input_path in
  let snapshot_path (case : M.case) =
    options.output_path ^ ".snapshot-" ^ Digestif.SHA256.(to_hex (digest_string case.id)) ^ ".json"
  in
  let rec check_snapshots = function
    | [] -> Ok ()
    | case :: rest ->
      let path = snapshot_path case in
      (match Fs_compat.exact_path_kind ~follow:false path with
       | Fs_compat.Exact_missing -> check_snapshots rest
       | Fs_compat.Exact_kind _ -> Error ("Snapshot already exists: " ^ path)
       | Fs_compat.Exact_unknown -> Error ("Cannot inspect snapshot path: " ^ path))
  in
  let* () = check_snapshots dataset.cases in
  let* config_revision, provider_cfg = prepare_runtime options in
  let identity = Masc.Build_identity.current () in
  let samples = List.map (fun case -> case, M.initial_progress) dataset.cases in
  let report samples =
    `Assoc
      [ "schema", `String "masc.librarian-working-state.v1"
      ; "provenance", R.provenance_to_yojson dataset.provenance
      ; "run_id", `String identity.runtime_instance_id
      ; "started_at", `String identity.started_at
      ; "input_path", `String options.input_path
      ; "input_sha256", `String Digestif.SHA256.(to_hex (digest_string input_bytes))
      ; "output_path", `String options.output_path
      ; "config_revision", `String config_revision
      ; "binary_commit", (match identity.binary_commit with None -> `Null | Some value -> `String value)
      ; "executable_sha256", (match identity.executable_sha256 with None -> `Null | Some value -> `String value)
      ; "samples", `List (List.map (fun (case, progress) -> `Assoc
          [ "case", M.case_to_yojson case
          ; "snapshot_path", `String (snapshot_path case)
          ; "progress", M.progress_to_yojson progress ]) samples)
      ]
  in
  let encode samples = Yojson.Safe.pretty_to_string (report samples) ^ "\n" in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Eio_context.set_env env;
      Eio_context.set_switch sw;
      Eio_context.set_net (Eio.Stdenv.net env);
      Eio_context.set_clock (Eio.Stdenv.clock env);
      Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
      Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
        let* () = create_report_bytes ~fs:(Eio.Stdenv.fs env)
          ~output_path:options.output_path (encode samples) in
        let generate = generate ~sw ~net:(Eio.Stdenv.net env)
          ~runtime_id:options.runtime_id ~provider_cfg in
        let endpoint = Masc.Typesafeai_config.endpoint () in
        let rec loop completed = function
          | [] -> Ok (List.rev completed)
          | (case, _) :: rest ->
            let save progress =
              Masc.Keeper_fs.save_bytes_durable_atomic options.output_path
                (encode (List.rev_append completed ((case, progress) :: rest)))
              |> Result.map_error Masc.Keeper_fs.durable_write_error_to_string
            in
            let* progress = M.evaluate_case ~generate
              ~judge:(judge ~clock:(Eio.Stdenv.clock env) ~endpoint)
              ~judge_endpoint:(Masc.Typesafeai_client.endpoint_for_observation endpoint)
              ~judge_model:(Masc.Typesafeai_config.model ())
              ~snapshot_path:(snapshot_path case) ~save case in
            loop ((case, progress) :: completed) rest
        in
        let* completed = loop [] samples in
        let arm_scored = function R.Scored _ -> true | _ -> false in
        let all_scored = List.for_all (fun (_, (progress : M.progress)) ->
          arm_scored progress.baseline && arm_scored progress.restored) completed in
        let bytes = encode completed in
        (* Reuse publication handling, which treats a blob as a copy. The
           comparison report itself remains the authoritative artifact. *)
        let publication = match options.publish_base_path with
          | None -> Ok None
          | Some base_path ->
            (try Ok (Some (Tool_blob_store.put_durable
               (Tool_blob_store.create ~base_path) ~bytes ~mime:"application/json").sha256)
             with Sys_error detail -> Error detail)
        in
        print_endline (Yojson.Safe.to_string (`Assoc
          ([ "output_path", `String options.output_path
           ; "sha256", `String Digestif.SHA256.(to_hex (digest_string bytes))
           ; "all_cases_scored", `Bool all_scored ]
           @ match publication with
             | Ok sha -> ["blob_sha256", (match sha with None -> `Null | Some value -> `String value)]
             | Error detail -> ["blob_sha256", `Null; "publication_error", `String detail])));
        Ok (if all_scored then 0 else 1))))

(* Storage/assembly experiment for RFC section 7(d). These explicit commands
   write only the requested artifact; they never advance a live read cursor. *)
type snapshot_mode = Capture | Restore

let snapshot_command mode =
  let module S = Masc.Librarian_continuity_snapshot in
  let module C = Masc.Keeper_checkpoint_store in
  let session_dir = ref None and trace_id = ref None in
  let keepers_dir = ref None and keeper = ref None in
  let state = ref None and snapshot = ref None and output = ref None in
  let set target value = target := Some value in
  let command = match mode with Capture -> "capture" | Restore -> "restore" in
  let common =
    [ "--session-dir", Arg.String (set session_dir), "Checkpoint session directory"
    ; "--trace", Arg.String (set trace_id), "Exact checkpoint trace ID"
    ; "--keepers-dir", Arg.String (set keepers_dir), "Runtime Keeper directory containing boundaries"
    ; "--keeper", Arg.String (set keeper), "Keeper owning the boundary log"
    ; "--output", Arg.String (set output), "New local artifact path (contains context text)"
    ] in
  let specific = match mode with
    | Capture -> [ "--working-state", Arg.String (set state), "Candidate ongoing-work text file" ]
    | Restore -> [ "--snapshot", Arg.String (set snapshot), "Previously captured continuity artifact" ]
  in
  let* () =
    try
      Arg.parse_argv ~current:(ref 1) Sys.argv (common @ specific)
        (fun argument -> raise (Arg.Bad ("Unexpected argument: " ^ argument)))
        ("masc-librarian-continuity " ^ command ^ " --session-dir DIR --trace ID --keepers-dir DIR --keeper NAME --output FILE");
      Ok ()
    with
    | Arg.Bad detail -> Error detail
    | Arg.Help detail -> print_string detail; exit 0
  in
  let required name value = match !value with
    | Some value when String.trim value <> "" -> Ok value
    | None | Some _ -> Error ("Missing or empty " ^ name)
  in
  let* session_dir = required "--session-dir" session_dir in
  let* trace_id = required "--trace" trace_id in
  let* keepers_dir = required "--keepers-dir" keepers_dir in
  let* keeper_id = required "--keeper" keeper in
  let* output_path = required "--output" output in
  let output_path = Config_dir_resolver.absolute_path output_path in
  let* () = match Fs_compat.exact_path_kind ~follow:false output_path with
    | Fs_compat.Exact_missing -> Ok ()
    | Fs_compat.Exact_kind _ -> Error ("Output already exists: " ^ output_path)
    | Fs_compat.Exact_unknown -> Error ("Cannot inspect output path: " ^ output_path)
  in
  let* lines = Masc.Keeper_turn_boundaries.read ~keepers_dir ~keeper_id in
  let* checkpoint = C.load_agent_core_exact_snapshot ~session_dir ~session_id:trace_id
    |> Result.map_error (function
      | C.Ref_not_found -> "Checkpoint not found"
      | C.Ref_read_failed error -> C.checkpoint_load_error_to_string error
      | C.Ref_identity_invalid _ -> "Checkpoint identity is invalid"
      | C.Ref_session_mismatch _ -> "Checkpoint trace does not match --trace"
      | C.Ref_lock_failed detail -> "Checkpoint lock failed: " ^ detail)
  in
  let messages = C.exact_snapshot_messages checkpoint in
  let* artifact = match mode with
    | Capture ->
      let* state_path = required "--working-state" state in
      let* working_state =
        try Ok (In_channel.with_open_bin state_path In_channel.input_all)
        with Sys_error detail -> Error detail
      in
      let* value = S.capture ~trace_id ~lines ~messages ~working_state
        |> Result.map_error S.error_to_string in
      Ok (S.to_json value)
    | Restore ->
      let* snapshot_path = required "--snapshot" snapshot in
      let* value = S.load ~path:snapshot_path |> Result.map_error S.error_to_string in
      let* restored = S.restore ~trace_id ~lines ~messages value
        |> Result.map_error S.error_to_string in
      Ok (`Assoc
        [ "schema", `String "masc.continuity-restoration.v1"
        ; "trace_id", `String trace_id
        ; "snapshot", S.to_json value
        ; "working_state", `String restored.working_state
        ; "messages", `List (List.map Agent_core.Checkpoint.message_to_json restored.messages)
        ])
  in
  let bytes = Yojson.Safe.pretty_to_string artifact ^ "\n" in
  let* () = Masc.Keeper_fs.save_bytes_durable_atomic output_path bytes
    |> Result.map_error Masc.Keeper_fs.durable_write_error_to_string in
  print_endline (Yojson.Safe.to_string (`Assoc
    [ "operation", `String command
    ; "output_path", `String output_path
    ; "sha256", `String Digestif.SHA256.(to_hex (digest_string bytes))
    ; "semantic_continuity_evaluated", `Bool false
    ]));
  Ok 0

let run_snapshot mode =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Eio_context.set_env env;
      Eio_context.set_switch sw;
      Eio_context.set_clock (Eio.Stdenv.clock env);
      Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      snapshot_command mode))

let () =
  let result =
    try match Array.to_list Sys.argv with
    | _ :: "compare" :: _ -> let* options = parse_options ~start:1 () in run_comparison options
    | _ :: "capture" :: _ -> run_snapshot Capture
    | _ :: "restore" :: _ -> run_snapshot Restore
    | _ -> let* options = parse_options () in run options
    with
    | Arg.Bad detail -> Error detail
    | Arg.Help detail -> print_string detail; exit 0
  in
  match result with
  | Ok code -> exit code
  | Error detail -> Log.Runtime.error "librarian-continuity: %s" detail; exit 2
