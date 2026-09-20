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
   --config runtime.toml --runtime EXACT_ID [--publish-base-path DIR]"

let parse_options () =
  let input = ref None and output = ref None and config = ref None in
  let runtime = ref None and publish = ref None in
  let set target value = target := Some value in
  Arg.parse
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

let read_dataset path =
  try
    let bytes = In_channel.with_open_bin path In_channel.input_all in
    let+ dataset = R.parse_dataset (Yojson.Safe.from_string bytes) in
    bytes, dataset
  with
  | Sys_error detail | Yojson.Json_error detail -> Error detail

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

let judge ~clock (request : R.judge_request) =
  let* api_key =
    match Masc.Typesafeai_config.api_key () with
    | None -> Error "TypeSafe API key is not configured"
    | Some api_key ->
        if Masc.Typesafeai_config.is_enabled () then Ok api_key
        else Error "TypeSafe evaluation is disabled by configuration"
  in
  let* evaluated =
    Masc.Typesafeai_client.evaluate ~clock ~api_key
      ~endpoint:request.endpoint ~model:request.model
      ~state:(R.judge_state request) ~questions:(R.judge_questions request) ()
  in
  R.judgment request evaluated

let save_report (report : R.t) =
  let bytes = Yojson.Safe.pretty_to_string (R.to_yojson report) ^ "\n" in
  let+ () =
    Masc.Keeper_fs.save_bytes_durable_atomic report.output_path bytes
    |> Result.map_error Masc.Keeper_fs.durable_write_error_to_string
  in
  bytes

let measure_case ~generate ~clock ~save (case : R.case) =
  match generate (R.question_prompt case.source) with
  | Error failed -> save (R.Question_failed failed)
  | Ok question ->
      let* _ = save (R.Question_ready question) in
      (match generate (R.answer_prompt ~question:question.response.text case.context) with
       | Error failed -> save (R.Answer_failed (question, failed))
       | Ok answer ->
           let* _ = save (R.Answer_ready (question, answer)) in
           let request =
             R.judge_request
               ~endpoint:(Masc.Typesafeai_config.endpoint ())
               ~model:(Masc.Typesafeai_config.model ()) case
               ~question:question.response.text ~answer:answer.response.text
           in
           match judge ~clock request with
           | Ok judgment -> save (R.Scored (question, answer, judgment))
           | Error error ->
               save (R.Judge_failed (question, answer, { request; error })))

let measure ~generate ~clock (report : R.t) =
  let* initial_bytes = save_report report in
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
    ; "sha256", `String (R.sha256 bytes)
    ; "all_cases_scored", `Bool (List.for_all scored report.R.samples)
    ]
  in
  let publication_fields, publication_ok =
    match published with
    | Ok blob ->
        [ "blob_sha256", (match blob with None -> `Null | Some sha -> `String sha) ], true
    | Error detail -> [ "blob_sha256", `Null; "publication_error", `String detail ], false
  in
  print_endline (Yojson.Safe.to_string (`Assoc (fields @ publication_fields)));
  flush stdout;
  if publication_ok && List.for_all scored report.samples then 0 else 1

let run options =
  let* input_bytes, dataset = read_dataset options.input_path in
  let* config_revision, provider_cfg = prepare_runtime options in
  let identity = Masc.Build_identity.current () in
  let report : R.t =
    { schema = R.schema
    ; run_id = identity.runtime_instance_id
    ; started_at = identity.started_at
    ; input_path = options.input_path
    ; input_sha256 = R.sha256 input_bytes
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
        let+ report, bytes = measure ~generate ~clock:(Eio.Stdenv.clock env) report in
        publish options report bytes)))

let () =
  let result = let* options = parse_options () in run options in
  match result with
  | Ok code -> exit code
  | Error detail -> Log.Runtime.error "librarian-continuity: %s" detail; exit 2
