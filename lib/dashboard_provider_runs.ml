module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

type discovery_info = {
  discovered_model : string option;
  ctx_size : int option;
  total_slots : int option;
  busy_slots : int option;
  idle_slots : int option;
  healthy : bool;
}

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
  discovery : discovery_info option;
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
let finished_run_ttl_seconds = Env_config.InternalTimers.provider_run_ttl_sec
let max_finished_runs = 128

let trim_nonempty value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed

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
      | Some finished_at when Stdlib.Float.compare (now_unix -. finished_at) finished_run_ttl_seconds > 0 ->
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
  let ts_ms = Stdlib.Int.of_float (Time_compat.now () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF in
  Printf.sprintf "run-%d-%06x" ts_ms hash

let model_id_of_label label =
  match String.index_opt label ':' with
  | Some idx when idx < String.length label - 1 ->
      let model =
        String.sub label (idx + 1) (String.length label - idx - 1)
        |> String.trim
      in
      if String.equal model "" then None else Some model
  | _ -> None

(* auth_kind_for_provider and endpoint_url_for_provider removed.
   Use Provider_adapter.auth_detail_of_provider instead. *)

let catalog_models_for_provider provider =
  match Provider_adapter.resolve_direct_adapter provider with
  | Some { canonical_name; _ }
    when Provider_id.matches_string Provider_id.llama canonical_name -> []
  | Some _ -> (
      match Provider_adapter.auto_models_for_provider provider with
      | Some models -> models
      | None -> [ "auto" ])
  | None -> []

let default_model_for_provider provider =
  match Provider_adapter.resolve_direct_adapter provider with
  | Some { canonical_name; _ }
    when Provider_id.matches_string Provider_id.llama canonical_name -> (
      match Provider_adapter.explicit_llama_model_id_result () with
      | Ok model_id -> trim_nonempty model_id
      | Error _ -> None)
  | Some { default_model_id; _ } -> (
      match catalog_models_for_provider provider with
      | first :: _ when not (String.equal (String.trim first) "") && not (String.equal first "auto") -> Some first
      | _ -> default_model_id)
  | None -> None

let candidate_models_for_provider provider =
  catalog_models_for_provider provider

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
  (* Merge OAS Discovery probe data for richer observability.
     Discovery_cache.get_cached_or_refresh is TTL-gated (30s),
     so this does not trigger extra network calls. *)
  let discovery =
    let endpoints = Discovery_cache.get_cached_or_refresh () in
    match endpoints with
    | [] -> None
    | ep :: _ ->
      let open Llm_provider.Discovery in
      Some {
        discovered_model = (match ep.props with
          | Some p when not (String.equal p.model "") -> Some p.model
          | _ -> (match ep.models with
                  | m :: _ -> Some m.id
                  | [] -> None));
        ctx_size = (match ep.props with Some p -> Some p.ctx_size | None -> None);
        total_slots = (match ep.props with Some p -> Some p.total_slots | None -> None);
        busy_slots = (match ep.slots with Some s -> Some s.busy | None -> None);
        idle_slots = (match ep.slots with Some s -> Some s.idle | None -> None);
        healthy = ep.healthy;
      }
  in
  {
    provider = "llama";
    kind = "local";
    runtime_kind = "local";
    auth_kind = "none";
    status;
    available;
    supports_single_agent_run = available && Stdlib.List.length models > 0;
    default_model = default_model_for_provider "llama";
    models;
    source = "masc/local-runtime";
    endpoint_url = (Provider_adapter.auth_detail_of_provider "llama").endpoint_url;
    note;
    discovery;
  }

(** Build snapshot for any direct-API provider.
    Vendor-specific logic (Gemini Vertex ADC, etc.) is encapsulated
    inside Provider_adapter.auth_detail_of_provider. *)
let provider_snapshot_of_adapter (adapter : Provider_adapter.adapter) =
  let provider = adapter.canonical_name in
  let detail = Provider_adapter.auth_detail_of_provider provider in
  let default_model = default_model_for_provider provider in
  let kind =
    match adapter.runtime_kind with
    | Provider_adapter.Local -> "local"
    | Provider_adapter.Cli_agent -> "cli"
    | Provider_adapter.Direct_api -> "cloud"
  in
  {
    provider;
    kind;
    runtime_kind = Provider_adapter.string_of_runtime_kind adapter.runtime_kind;
    auth_kind = detail.auth_kind;
    status = detail.status;
    available = detail.available;
    supports_single_agent_run = detail.supports_run && Option.is_some default_model;
    default_model;
    models = candidate_models_for_provider provider;
    source = "masc/provider-adapter";
    endpoint_url = detail.endpoint_url;
    note = detail.note;
    discovery = None;
  }

let provider_snapshots () : provider_snapshot list =
  let managed =
    Provider_adapter.direct_adapters
    |> List.filter (fun (a : Provider_adapter.adapter) ->
         not ((=) a.runtime_kind Provider_adapter.Local)
         && Option.is_some a.default_model_id)
    |> List.map provider_snapshot_of_adapter
  in
  llama_snapshot () :: managed

let provider_snapshot_by_name name =
  provider_snapshots ()
  |> List.find_opt (fun (snapshot : provider_snapshot) ->
         String.equal snapshot.provider name)

let discovery_info_to_json (d : discovery_info) : (string * Yojson.Safe.t) list =
  let opt_int k = function Some n -> [(k, `Int n)] | None -> [] in
  let opt_str k = function Some s -> [(k, `String s)] | None -> [] in
  [("discovery", `Assoc (
    [("healthy", `Bool d.healthy)]
    @ opt_str "discovered_model" d.discovered_model
    @ opt_int "ctx_size" d.ctx_size
    @ opt_int "total_slots" d.total_slots
    @ opt_int "busy_slots" d.busy_slots
    @ opt_int "idle_slots" d.idle_slots
  ))]

let provider_snapshot_to_json (snapshot : provider_snapshot) =
  let base = [
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
  ] in
  let disc = match snapshot.discovery with
    | Some d -> discovery_info_to_json d
    | None -> []
  in
  `Assoc (base @ disc)

let provider_inventory_json () =
  let snapshots = provider_snapshots () in
  let local_models =
    snapshots
    |> List.filter (fun snapshot -> String.equal snapshot.kind "local")
    |> List.fold_left
         (fun acc snapshot -> acc + List.length snapshot.models)
         0
  in
  let cloud_models =
    snapshots
    |> List.filter (fun snapshot -> String.equal snapshot.runtime_kind "direct_api")
    |> List.fold_left
         (fun acc snapshot -> acc + List.length snapshot.models)
         0
  in
  let cli_models =
    snapshots
    |> List.filter (fun snapshot -> String.equal snapshot.runtime_kind "cli_agent")
    |> List.fold_left
         (fun acc snapshot -> acc + List.length snapshot.models)
         0
  in
  `Assoc
    [
      ("updated_at", `String (Masc_domain.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("providers", `Int (List.length snapshots));
            ("local_models", `Int local_models);
            ("cloud_models", `Int cloud_models);
            ("cli_models", `Int cli_models);
          ] );
      ( "providers",
        `List (List.map provider_snapshot_to_json snapshots) );
    ]

let response_text_of_api_response (response : Agent_sdk.Types.api_response) =
  Agent_sdk.Types.text_of_content response.content |> String.trim

let provider_label_for_model provider model =
  match Provider_adapter.resolve_direct_adapter provider with
  | Some adapter ->
    Ok (Provider_adapter.cascade_prefix_of_adapter adapter ^ ":" ^ model)
  | None ->
    Error
      (Printf.sprintf
         "Unsupported provider '%s' for dashboard single-agent runs"
         provider)

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
            if Stdlib.List.length snapshot.models > 0 && not (List.mem model snapshot.models) then
              Error
                (Printf.sprintf
                   "Model '%s' is not available for provider '%s'"
                   model provider)
            else if String.equal (String.trim prompt) "" then
              Error "prompt is required"
            else
              Ok (snapshot, model))

(** Check if a model label is runnable (has provider config + auth). *)
let is_label_runnable (label : string) : bool =
  match Cascade_config.parse_model_string label with
  | None -> false
  | Some _cfg ->
    (* Extract provider prefix from label and check auth detail *)
    match String.index_opt label ':' with
    | None -> false
    | Some idx ->
      let prefix = String.sub label 0 idx |> String.trim in
      let detail = Provider_adapter.auth_detail_of_provider prefix in
      detail.available && detail.supports_run

let run_system_prompt provider =
  Printf.sprintf
    "You are a single MASC dashboard run using provider %s. Answer directly, keep tool use disabled, and return only the final answer."
    provider

let execute_single_agent_run ~sw ~net ~run_id ~provider ~model ~prompt =
  let label_result = provider_label_for_model provider model in
  match label_result with
  | Error _ as error -> error
  | Ok label -> (
      Log.info ~ctx:"dashboard_provider_runs"
        "single-agent run resolved run_id=%s provider=%s requested_model=%s model_label=%s"
        run_id provider model label;
      (* Validate label parses *)
      match Cascade_config.parse_model_string label with
      | None -> Error (Printf.sprintf "Cannot parse model: %s" label)
      | Some _cfg ->
        if not (is_label_runnable label) then
          Error
            (Printf.sprintf
               "Provider '%s' is not runnable in dashboard single-agent mode"
               provider)
        else (
          let inference_cascade_name =
            Keeper_cascade_profile.Runtime_name
              (Keeper_cascade_profile.cascade_name_for_use
                 Keeper_cascade_profile.Provider_benchmark)
          in
          match
            Masc_oas_bridge.run_with_caller
              ~caller:Env_config_oas_bridge.Dashboard_provider_runs (fun () ->
              Oas_worker.run_model_by_label ~model_label:label ~goal:prompt
                ~system_prompt:(run_system_prompt provider)
                ~max_turns:4
                ~max_tokens:(Cascade_inference.resolve_max_tokens
                  ~cascade_name:inference_cascade_name
                  ~fallback:(fun () -> 2048))
                ~temperature:(Cascade_inference.resolve_temperature
                  ~cascade_name:inference_cascade_name
                  ~fallback:(fun () -> 0.2))
                ~sw ?net
                ()
            )
          with
          | Ok result ->
              Ok (response_text_of_api_response result.response)
          | Error err -> Error (Agent_sdk.Error.to_string err)))

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
          created_at = Masc_domain.now_iso ();
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
      Log.info ~ctx:"dashboard_provider_runs"
        "single-agent run queued run_id=%s provider=%s model=%s"
        run.run_id run.provider run.model;
      Eio.Fiber.fork ~sw (fun () ->
          let mark_failed message =
            Log.warn ~ctx:"dashboard_provider_runs"
              "single-agent run failed run_id=%s provider=%s model=%s error=%s"
              run.run_id run.provider run.model message;
            update_run_record run.run_id (fun current ->
                current.status <- Failed;
                current.finished_at <- Some (Masc_domain.now_iso ());
                current.finished_at_unix <- Some (Unix.gettimeofday ());
                current.output <- None;
                current.error <- Some message)
          in
          try
            update_run_record run.run_id (fun current ->
                current.status <- Running;
                current.started_at <- Some (Masc_domain.now_iso ()));
            match
              execute_single_agent_run ~sw ~net ~run_id:run.run_id
                ~provider:run.provider
                ~model:run.model
                ~prompt:run.prompt
            with
            | Ok output ->
                Log.info ~ctx:"dashboard_provider_runs"
                  "single-agent run completed run_id=%s provider=%s model=%s"
                  run.run_id run.provider run.model;
                update_run_record run.run_id (fun current ->
                    current.status <- Completed;
                    current.finished_at <- Some (Masc_domain.now_iso ());
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
                 (Stdlib.Printexc.to_string exn)));
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
