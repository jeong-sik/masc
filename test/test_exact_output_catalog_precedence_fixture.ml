module Exact_output = Agent_sdk.Exact_output
module Registry = struct
  include Runtime_exact_output_registry
  include Runtime_exact_output_registry.For_testing
end

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)
;;

let rec mkdir_p path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let overlay_target = "overlay-only-target"
let replacement_target = "replacement-only-target"
let embedded_target = "ollama-cloud-minimax-m3-json"

let catalog_toml ?(api_key_env = "") ~provider_id ~model_id ~target_id () =
  Printf.sprintf
    {|[[providers]]
id = %S
kind = "openai_compat"
base_url = "http://127.0.0.1:1"
request_path = "/v1/chat/completions"
api_key_env = %S

[[models]]
id_prefix = %S
provider_name = %S
max_context_tokens = 8192
max_output_tokens = 1024
supports_response_format_json = true
supports_structured_output = false
input_per_million = 1.0

[[targets]]
id = %S
provider_ref = %S
model_id = %S
|}
    provider_id
    api_key_env
    model_id
    provider_id
    target_id
    provider_id
    model_id
;;

let overlay_catalog =
  catalog_toml
    ~provider_id:"overlay_provider"
    ~model_id:"overlay-model"
    ~target_id:overlay_target
    ()
;;

let replacement_catalog =
  catalog_toml
    ~provider_id:"replacement_provider"
    ~model_id:"replacement-model"
    ~target_id:replacement_target
    ()
;;

let runtime_toml lane_target =
  Printf.sprintf
    {|[providers.replacement_provider]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1/v1"

[models.replacement]
api-name = "replacement-model"
max-context = 8192

[replacement_provider.replacement]

[runtime]
default = "replacement_provider.replacement"

[runtime.exact_output_lanes.compaction_exact]
slots = [%S]
|}
    lane_target
;;

let failed_runtime_toml =
  {|[providers.replacement_provider]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1/v1"

[models.alternate]
api-name = "replacement-model"
max-context = 8192

[replacement_provider.alternate]

[runtime]
default = "replacement_provider.alternate"
|}
;;

let load_snapshot ~getenv catalog =
  let io : Exact_output.resolver_io = { getenv } in
  match Exact_output.load_resolver_snapshot ~io ~catalog () with
  | Ok snapshot -> snapshot
  | Error _ -> Alcotest.fail "OAS control snapshot must load"
;;

let load_control_snapshot catalog = load_snapshot ~getenv:(fun _ -> Ok None) catalog

let require_admitted snapshot target_id =
  match Exact_output.admit_target_ref snapshot target_id with
  | Ok _ -> ()
  | Error _ -> Alcotest.failf "OAS control target %S must be admitted" target_id
;;

let require_not_admitted snapshot target_id =
  match Exact_output.admit_target_ref snapshot target_id with
  | Error (Exact_output.Target_not_in_catalog actual) ->
    Alcotest.(check string) "excluded target identity" target_id actual
  | Error _ -> Alcotest.failf "target %S returned the wrong exclusion" target_id
  | Ok _ -> Alcotest.failf "target %S survived full replacement" target_id
;;

let require_registry_unpublished label =
  match Registry.current () with
  | Error Registry.Registry_not_published -> ()
  | Error error ->
    Alcotest.failf
      "%s returned the wrong unpublished failure: %s"
      label
      (Registry.publication_error_to_string error)
  | Ok _ -> Alcotest.failf "%s must leave the registry unpublished" label
;;

let require_publication_busy label = function
  | Error Registry.Publication_busy -> ()
  | Error error ->
    Alcotest.failf
      "%s returned the wrong failure: %s"
      label
      (Registry.publication_error_to_string error)
  | Ok _ -> Alcotest.failf "%s crossed the active reservation" label
;;

let require_reservation_inactive label = function
  | Error Registry.Reservation_inactive -> ()
  | Ok () -> Alcotest.failf "%s accepted an inactive reservation" label
;;

let require_replacement_base_changed label ~expected_generation ~actual_generation =
  function
  | Error
      (Registry.Replacement_base_changed
         { expected_generation = actual_expected
         ; actual_generation = actual_actual
         }) ->
    Alcotest.(check (option int64))
      (label ^ " expected generation")
      expected_generation
      actual_expected;
    Alcotest.(check (option int64))
      (label ^ " actual generation")
      actual_generation
      actual_actual
  | Error error ->
    Alcotest.failf
      "%s returned the wrong failure: %s"
      label
      (Registry.publication_error_to_string error)
  | Ok _ -> Alcotest.failf "%s accepted a stale prepared replacement" label
;;
