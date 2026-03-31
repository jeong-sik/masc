
module Oas = Agent_sdk

type provider_snapshot = {
  provider : string;
  kind : string;
  runtime_kind : string;
  auth_kind : string;
  status : string;
  available : bool;
  supports_single_agent_run : bool;
  default_model : string option;
  models : string list;
  source : string;
  endpoint_url : string option;
  note : string option;
}

type run_status =
  | Queued
  | Running
  | Completed
  | Failed

type run_record = {
  run_id : string;
  provider : string;
  model : string;
  prompt : string;
  created_at : string;
  created_at_unix : float;
  mutable status : run_status;
  mutable started_at : string option;
  mutable finished_at : string option;
  mutable finished_at_unix : float option;
  mutable output : string option;
  mutable error : string option;
}

let provider_runs : (string, run_record) Hashtbl.t = Hashtbl.create 32
let provider_runs_mutex = Eio.Mutex.create ()
let finished_run_ttl_seconds = 3600.0
let max_finished_runs = 128

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let dedupe_keep_order values =
  values
  |> List.filter_map trim_nonempty
  |> Json_util.dedupe_keep_order

let string_of_run_status = function
  | Queued -> "queued"
  | Running -> "running"
  | Completed -> "completed"
  | Failed -> "failed"

let run_record_to_json (run : run_record) =
  `Assoc
    [
      ("run_id", `String run.run_id);
      ("status", `String (string_of_run_status run.status));
      ("provider", `String run.provider);
      ("model", `String run.model);
      ("created_at", `String run.created_at);
      ("started_at", Json_util.string_opt_to_json run.started_at);
      ("finished_at", Json_util.string_opt_to_json run.finished_at);
      ("output", Json_util.string_opt_to_json run.output);
      ("error", Json_util.string_opt_to_json run.error);
    ]

let is_terminal_status = function
  | Completed | Failed -> true
  | Queued | Running -> false

let run_sort_key (run : run_record) =
  match run.finished_at_unix with Some ts -> ts | None -> run.created_at_unix

let rec drop_oldest_finished overflow records =
  match (overflow, records) with
  | n, _ when n <= 0 -> ()
  | _, [] -> ()
  | n, (run_id, _) :: rest ->
      Hashtbl.remove provider_runs run_id;
      drop_oldest_finished (n - 1) rest

let prune_run_records_locked now_unix =
  let expired_finished = ref [] in
  let finished_records = ref [] in
  Hashtbl.iter
    (fun run_id run ->
      match run.finished_at_unix with
      | Some finished_at when now_unix -. finished_at > finished_run_ttl_seconds ->
          expired_finished := run_id :: !expired_finished
      | Some _ when is_terminal_status run.status ->
          finished_records := (run_id, run_sort_key run) :: !finished_records
      | _ -> ())
    provider_runs;
  List.iter (fun run_id -> Hashtbl.remove provider_runs run_id) !expired_finished;
  let overflow = List.length !finished_records - max_finished_runs in
  if overflow > 0 then
    !finished_records
    |> List.sort (fun (_, left) (_, right) -> Float.compare left right)
    |> drop_oldest_finished overflow

let set_run_record run =
  Eio.Mutex.use_rw ~protect:true provider_runs_mutex (fun () ->
      Hashtbl.replace provider_runs run.run_id run;
      prune_run_records_locked (Unix.gettimeofday ()))

let update_run_record run_id f =
  Eio.Mutex.use_rw ~protect:true provider_runs_mutex (fun () ->
      match Hashtbl.find_opt provider_runs run_id with
      | Some run ->
          f run;
          prune_run_records_locked (Unix.gettimeofday ())
      | None -> ())

let find_run_record run_id =
  Eio.Mutex.use_ro provider_runs_mutex (fun () ->
      Hashtbl.find_opt provider_runs run_id)

let make_run_id () =
  let ts_ms = int_of_float (Time_compat.now () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF in
  Printf.sprintf "run-%d-%06x" ts_ms hash

let model_id_of_label label =
  match String.index_opt label ':' with
  | Some idx when idx < String.length label - 1 ->
      let model =
        String.sub label (idx + 1) (String.length label - idx - 1)
        |> String.trim
      in
      if model = "" then None else Some model
  | _ -> None

let auth_kind_for_provider provider =
  match provider with
  | "claude-api" -> "api_key:ANTHROPIC_API_KEY"
  | "codex-api" -> "api_key:OPENAI_API_KEY"
  | "glm" -> "api_key:ZAI_API_KEY"
  | "gemini-api" -> (
      match Provider_adapter.resolve_gemini_direct_auth () with
      | Provider_adapter.Gemini_api_key -> "api_key:GEMINI_API_KEY"
      | Provider_adapter.Gemini_vertex_adc { project; location } ->
          Printf.sprintf "vertex_adc:%s:%s" project location
      | Provider_adapter.Gemini_auth_missing _ ->
          "vertex_adc:GOOGLE_CLOUD_PROJECT:GOOGLE_CLOUD_LOCATION")
  | "llama" -> "none"
  | _ -> "unknown"

let endpoint_url_for_provider provider =
  match provider with
  | "llama" -> Some Env_config_runtime.Llama.server_url
  | "claude-api" -> Some "https://api.anthropic.com"
  | "codex-api" -> Some "https://api.openai.com"
  | "glm" -> Some "https://api.z.ai"
  | "gemini-api" -> (
      match Provider_adapter.resolve_gemini_direct_auth () with
      | Provider_adapter.Gemini_vertex_adc { project; location } ->
          Some
            (Provider_adapter.gemini_vertex_openai_base_url ~project ~location)
      | _ -> Some "https://generativelanguage.googleapis.com")
  | _ -> None

let default_model_for_provider provider =
  match provider with
  | "llama" -> (
      match Provider_adapter.explicit_llama_model_id_result () with
      | Ok model_id -> trim_nonempty model_id
      | Error _ ->
          (match trim_nonempty Env_config_runtime.Llama.default_model with
          | Some value when value <> "explicit-model-required" -> Some value
          | _ -> None))
  | "claude-api" -> trim_nonempty Env_config_governance.Claude.default_model
  | "codex-api" -> trim_nonempty Env_config_governance.OpenAI.default_model
  | "gemini-api" -> trim_nonempty Env_config_governance.Gemini.default_model
  | "glm" -> Some "auto"
  | _ -> None

let candidate_models_for_provider provider =
  match provider with
  | "llama" -> []
  | "claude-api" ->
      dedupe_keep_order [ Env_config_governance.Claude.default_model ]
  | "codex-api" ->
      dedupe_keep_order [ Env_config_governance.OpenAI.default_model ]
  | "gemini-api" ->
      dedupe_keep_order
        [
          Env_config_governance.Gemini.default_model;
          Env_config_governance.Gemini.flash_model;
        ]
  | "glm" -> ["auto"]
  | _ -> []

let llama_snapshot () =
  let discovered_models, status, available, note =
    match Tool_local_runtime_core.fetch_models_at Env_config_runtime.Llama.server_url with
    | Ok (_url, models) -> (models, "online", true, None)
    | Error message -> ([], "offline", false, Some message)
  in
  let models =
    dedupe_keep_order
      (discovered_models @ Option.to_list (default_model_for_provider "llama"))
  in
  {
    provider = "llama";
    kind = "local";
    runtime_kind = "local";
    auth_kind = "none";
    status;
    available;
    supports_single_agent_run = available && models <> [];
    default_model = default_model_for_provider "llama";
    models;
    source = "masc/local-runtime";
    endpoint_url = endpoint_url_for_provider "llama";
    note;
  }

let direct_provider_snapshot provider =
  match provider with
  | "claude-api" ->
      let available = Provider_adapter.env_present "ANTHROPIC_API_KEY" in
      let default_model = default_model_for_provider provider in
      {
        provider;
        kind = "cloud";
        runtime_kind = "direct_api";
        auth_kind = auth_kind_for_provider provider;
        status = if available then "configured" else "missing_auth";
        available;
        supports_single_agent_run = available && default_model <> None;
        default_model;
        models = candidate_models_for_provider provider;
        source = "masc/provider-adapter";
        endpoint_url = endpoint_url_for_provider provider;
        note = None;
      }
  | "codex-api" ->
      let available = Provider_adapter.env_present "OPENAI_API_KEY" in
      let default_model = default_model_for_provider provider in
      {
        provider;
        kind = "cloud";
        runtime_kind = "direct_api";
        auth_kind = auth_kind_for_provider provider;
        status = if available then "configured" else "missing_auth";
        available;
        supports_single_agent_run = available && default_model <> None;
        default_model;
        models = candidate_models_for_provider provider;
        source = "masc/provider-adapter";
        endpoint_url = endpoint_url_for_provider provider;
        note = None;
      }
  | "glm" ->
      let available = Provider_adapter.env_present "ZAI_API_KEY" in
      let default_model = default_model_for_provider provider in
      {
        provider;
        kind = "cloud";
        runtime_kind = "direct_api";
        auth_kind = auth_kind_for_provider provider;
        status = if available then "configured" else "missing_auth";
        available;
        supports_single_agent_run = available && default_model <> None;
        default_model;
        models = candidate_models_for_provider provider;
        source = "masc/provider-adapter";
        endpoint_url = endpoint_url_for_provider provider;
        note = None;
      }
  | "gemini-api" -> (
      let default_model = default_model_for_provider provider in
      match Provider_adapter.resolve_gemini_direct_auth () with
      | Provider_adapter.Gemini_api_key ->
          {
            provider;
            kind = "cloud";
            runtime_kind = "direct_api";
            auth_kind = auth_kind_for_provider provider;
            status = "configured";
            available = true;
            supports_single_agent_run = default_model <> None;
            default_model;
            models = candidate_models_for_provider provider;
            source = "masc/provider-adapter";
            endpoint_url = endpoint_url_for_provider provider;
            note = None;
          }
      | Provider_adapter.Gemini_vertex_adc _ ->
          {
            provider;
            kind = "cloud";
            runtime_kind = "direct_api";
            auth_kind = auth_kind_for_provider provider;
            status = "vertex_adc";
            available = true;
            supports_single_agent_run = false;
            default_model;
            models = candidate_models_for_provider provider;
            source = "masc/provider-adapter";
            endpoint_url = endpoint_url_for_provider provider;
            note =
              Some
                "Dashboard run MVP only supports Gemini via GEMINI_API_KEY. Vertex ADC inventory is visible but run is disabled.";
          }
      | Provider_adapter.Gemini_auth_missing message ->
          {
            provider;
            kind = "cloud";
            runtime_kind = "direct_api";
            auth_kind = auth_kind_for_provider provider;
            status = "missing_auth";
            available = false;
            supports_single_agent_run = false;
            default_model;
            models = candidate_models_for_provider provider;
            source = "masc/provider-adapter";
            endpoint_url = endpoint_url_for_provider provider;
            note = Some message;
          })
  | other ->
      {
        provider = other;
        kind = "cloud";
        runtime_kind = "direct_api";
        auth_kind = "unknown";
        status = "unsupported";
        available = false;
        supports_single_agent_run = false;
        default_model = None;
        models = [];
        source = "masc/provider-adapter";
        endpoint_url = None;
        note = Some "Unsupported provider";
      }

let provider_snapshots () : provider_snapshot list =
  [
    llama_snapshot ();
    direct_provider_snapshot "claude-api";
    direct_provider_snapshot "codex-api";
    direct_provider_snapshot "gemini-api";
    direct_provider_snapshot "glm";
  ]

let provider_snapshot_by_name name =
  provider_snapshots ()
  |> List.find_opt (fun (snapshot : provider_snapshot) ->
         String.equal snapshot.provider name)

let provider_snapshot_to_json (snapshot : provider_snapshot) =
  `Assoc
    [
      ("provider", `String snapshot.provider);
      ("kind", `String snapshot.kind);
      ("runtime_kind", `String snapshot.runtime_kind);
      ("auth_kind", `String snapshot.auth_kind);
      ("status", `String snapshot.status);
      ("available", `Bool snapshot.available);
      ("supports_single_agent_run", `Bool snapshot.supports_single_agent_run);
      ("default_model", Json_util.string_opt_to_json snapshot.default_model);
      ("model_count", `Int (List.length snapshot.models));
      ("models", `List (List.map (fun model -> `String model) snapshot.models));
      ("source", `String snapshot.source);
      ("endpoint_url", Json_util.string_opt_to_json snapshot.endpoint_url);
      ("note", Json_util.string_opt_to_json snapshot.note);
    ]

let provider_inventory_json () =
  let snapshots = provider_snapshots () in
  let local_models =
    snapshots
    |> List.filter (fun snapshot -> snapshot.kind = "local")
    |> List.fold_left
         (fun acc snapshot -> acc + List.length snapshot.models)
         0
  in
  let cloud_models =
    snapshots
    |> List.filter (fun snapshot -> snapshot.kind <> "local")
    |> List.fold_left
         (fun acc snapshot -> acc + List.length snapshot.models)
         0
  in
  `Assoc
    [
      ("updated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("providers", `Int (List.length snapshots));
            ("local_models", `Int local_models);
            ("cloud_models", `Int cloud_models);
          ] );
      ( "providers",
        `List (List.map provider_snapshot_to_json snapshots) );
    ]

let response_text_of_api_response (response : Oas.Types.api_response) =
  Agent_sdk.Types.text_of_content response.content |> String.trim

let provider_label_for_model provider model =
  match provider with
  | "llama" -> Ok ("llama:" ^ model)
  | "claude-api" -> Ok ("claude:" ^ model)
  | "codex-api" -> Ok ("openai:" ^ model)
  | "gemini-api" -> Ok ("gemini:" ^ model)
  | "glm" -> Ok ("glm:" ^ model)
  | other ->
      Error
        (Printf.sprintf
           "Unsupported provider '%s' for dashboard single-agent runs"
           other)

let resolve_provider_run_request ~provider ~model_opt ~prompt =
  match provider_snapshot_by_name provider with
  | None ->
      Error (Printf.sprintf "Unknown provider '%s'" provider)
  | Some snapshot ->
      if not snapshot.supports_single_agent_run then
        Error
          (Option.value snapshot.note
             ~default:
               (Printf.sprintf
                  "Provider '%s' is not available for dashboard single-agent runs"
                  provider))
      else
        let selected_model =
          match Option.bind model_opt trim_nonempty with
          | Some model -> Some model
          | None -> snapshot.default_model
        in
        (match selected_model with
        | None ->
            Error
              (Printf.sprintf
                 "Provider '%s' requires an explicit model"
                 provider)
        | Some model ->
            if snapshot.models <> [] && not (List.mem model snapshot.models) then
              Error
                (Printf.sprintf
                   "Model '%s' is not available for provider '%s'"
                   model provider)
            else if String.trim prompt = "" then
              Error "prompt is required"
            else
              Ok (snapshot, model))

(** Check if a model label is runnable (has provider config + Gemini auth check). *)
let is_label_runnable (label : string) : bool =
  match Llm_provider.Cascade_config.parse_model_string label with
  | None -> false
  | Some cfg ->
    let rn = Llm_provider.Provider_config.(match cfg.kind with Anthropic -> "claude" | Gemini -> "gemini" | Glm -> "glm" | OpenAI_compat -> "openai" | Claude_code -> "claude") in
    match rn with
    | "gemini" -> (
        match Provider_adapter.resolve_gemini_direct_auth () with
        | Provider_adapter.Gemini_api_key -> true
        | Provider_adapter.Gemini_vertex_adc _ -> false
        | Provider_adapter.Gemini_auth_missing _ -> false)
    | _ -> Llm_provider.Cascade_config.parse_model_string label <> None

let run_system_prompt provider =
  Printf.sprintf
    "You are a single MASC dashboard run using provider %s. Answer directly, keep tool use disabled, and return only the final answer."
    provider

let execute_single_agent_run ~sw ~net ~provider ~model ~prompt =
  let label_result = provider_label_for_model provider model in
  match label_result with
  | Error _ as error -> error
  | Ok label -> (
      (* Validate label parses *)
      match Llm_provider.Cascade_config.parse_model_string label with
      | None -> Error (Printf.sprintf "Cannot parse model: %s" label)
      | Some _cfg ->
        if not (is_label_runnable label) then
          Error
            (Printf.sprintf
               "Provider '%s' is not runnable in dashboard single-agent mode"
               provider)
        else (
          match
            Oas_worker.run_model_by_label ~model_label:label ~goal:prompt
              ~system_prompt:(run_system_prompt provider)
              ~max_turns:4
              ~max_tokens:(Cascade_inference.resolve_max_tokens
                ~cascade_name:"provider_benchmark" ~fallback:(fun () -> 2048))
              ~temperature:(Cascade_inference.resolve_temperature
                ~cascade_name:"provider_benchmark" ~fallback:(fun () -> 0.2))
              ~priority:Llm_provider.Request_priority.Interactive
              ~sw ?net
              ()
          with
          | Ok result ->
              Ok (response_text_of_api_response result.response)
          | Error error -> Error error))

let start_run ~sw ~net ~provider ~model_opt ~prompt =
  match resolve_provider_run_request ~provider ~model_opt ~prompt with
  | Error _ as error -> error
  | Ok (_snapshot, model) ->
      let created_at_unix = Unix.gettimeofday () in
      let run =
        {
          run_id = make_run_id ();
          provider;
          model;
          prompt = String.trim prompt;
          created_at = Types.now_iso ();
          created_at_unix;
          status = Queued;
          started_at = None;
          finished_at = None;
          finished_at_unix = None;
          output = None;
          error = None;
        }
      in
      set_run_record run;
      Eio.Fiber.fork ~sw (fun () ->
          let mark_failed message =
            update_run_record run.run_id (fun current ->
                current.status <- Failed;
                current.finished_at <- Some (Types.now_iso ());
                current.finished_at_unix <- Some (Unix.gettimeofday ());
                current.output <- None;
                current.error <- Some message)
          in
          try
            update_run_record run.run_id (fun current ->
                current.status <- Running;
                current.started_at <- Some (Types.now_iso ()));
            match
              execute_single_agent_run ~sw ~net ~provider:run.provider
                ~model:run.model
                ~prompt:run.prompt
            with
            | Ok output ->
                update_run_record run.run_id (fun current ->
                    current.status <- Completed;
                    current.finished_at <- Some (Types.now_iso ());
                    current.finished_at_unix <- Some (Unix.gettimeofday ());
                    current.output <- Some output;
                    current.error <- None)
            | Error message -> mark_failed message
          with
          | Eio.Cancel.Cancelled _ as exn ->
              mark_failed "Dashboard single-agent run cancelled";
              raise exn
          | exn ->
            mark_failed
              (Printf.sprintf
                 "Dashboard single-agent run crashed: %s"
                 (Printexc.to_string exn)));
      Ok
        (`Assoc
          [
            ("run_id", `String run.run_id);
            ("status", `String (string_of_run_status run.status));
            ("provider", `String run.provider);
            ("model", `String run.model);
          ])

let run_status_json run_id =
  match find_run_record run_id with
  | Some run -> Ok (run_record_to_json run)
  | None ->
      Error (Printf.sprintf "run_id '%s' not found" run_id)
