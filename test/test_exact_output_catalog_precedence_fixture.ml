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

let transaction_lanes lane_id : Runtime_schema.exact_output_lane_decl list =
  [ { id = lane_id; slot_ids = [ replacement_target ] } ]
;;

let require_transaction_lane label ~lane_id registry =
  match Registry.resolve_lane registry ~lane_id with
  | Error error ->
    Alcotest.failf
      "%s: %s"
      label
      (Registry.lane_resolution_error_to_string error)
  | Ok { selected_slots; unavailable_slots } ->
    Alcotest.(check int)
      (label ^ " unavailable")
      0
      (List.length unavailable_slots);
    Alcotest.(check (list string))
      label
      [ replacement_target ]
      (List.map
         (fun (slot : Registry.selected_slot) -> slot.slot_id)
         selected_slots)
;;

let transaction_runtime_toml ~runtime_name ~lane_id =
  Printf.sprintf
    {|[providers.replacement_provider]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1/v1"

[models.%s]
api-name = "replacement-model"
max-context = 8192

[replacement_provider.%s]

[runtime]
default = %S

[runtime.exact_output_lanes.%s]
slots = [%S]
|}
    runtime_name
    runtime_name
    ("replacement_provider." ^ runtime_name)
    lane_id
    replacement_target
;;

let current_registry label =
  match Registry.current () with
  | Ok registry -> registry
  | Error error ->
    Alcotest.failf
      "%s: %s"
      label
      (Registry.publication_error_to_string error)
;;

let test_closed_registry_transaction () =
  let snapshot =
    load_control_snapshot
      (Exact_output.Full_replacement
         { source = "<fixture:replacement-catalog>"; contents = replacement_catalog })
  in
  let baseline =
    match Registry.publish ~lanes:(transaction_lanes "transaction-a") snapshot with
    | Ok registry -> registry
    | Error error ->
      Alcotest.failf
        "baseline publication failed: %s"
        (Registry.publication_error_to_string error)
  in
  let prepare lane_id =
    match Registry.prepare_replacement ~lanes:(transaction_lanes lane_id) with
    | Ok prepared -> prepared
    | Error error ->
      Alcotest.failf
        "transaction preparation failed: %s"
        (Registry.publication_error_to_string error)
  in
  (match
     Registry.transact_replacement
       (prepare "transaction-b")
       ~apply_write:(fun () ->
         Registry.current ()
         |> require_publication_busy "transaction callback acquisition";
         Registry.Not_committed ())
   with
   | Ok (Registry.Not_committed ()) -> ()
   | Ok (Registry.Committed _) -> Alcotest.fail "not-committed write published"
   | Error error ->
     Alcotest.failf
       "not-committed transaction failed: %s"
       (Registry.publication_error_to_string error));
  let unchanged = current_registry "transaction fence leaked after abort" in
  Alcotest.(check int64)
    "abort preserves generation"
    (Registry.generation baseline)
    (Registry.generation unchanged);
  require_transaction_lane
    "abort preserves lane"
    ~lane_id:"transaction-a"
    unchanged;
  (match
     Registry.transact_replacement
       (prepare "transaction-b")
       ~apply_write:(fun () -> Registry.Committed ())
   with
   | Ok (Registry.Committed ()) -> ()
   | Ok (Registry.Not_committed _) -> Alcotest.fail "committed write was aborted"
   | Error error ->
     Alcotest.failf
       "committed transaction failed: %s"
       (Registry.publication_error_to_string error));
  let committed = current_registry "transaction fence leaked after commit" in
  Alcotest.(check int64)
    "commit advances generation once"
    (Int64.succ (Registry.generation baseline))
    (Registry.generation committed);
  require_transaction_lane
    "commit publishes final lane"
    ~lane_id:"transaction-b"
    committed
;;

exception Injected_parent_sync_failure

let test_offline_runtime_save_converges_by_write_stage () =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       with_temp_dir "exact-output-offline-runtime-save" @@ fun root ->
       let path = Filename.concat root "runtime.toml" in
       let config_a =
         transaction_runtime_toml
           ~runtime_name:"replacement"
           ~lane_id:"offline-a"
       in
       let config_b =
         transaction_runtime_toml
           ~runtime_name:"alternate"
           ~lane_id:"offline-b"
       in
       require_registry_unpublished "offline baseline";
       (match Runtime.save_config_text ~runtime_config_path:path config_a with
        | Ok () -> ()
        | Error error -> Alcotest.failf "offline durable save failed: %s" error);
       Alcotest.(check string)
         "offline durable file converges to A"
         config_a
         (Fs_compat.load_file path);
       Alcotest.(check string)
         "offline durable cache converges to A"
         "replacement_provider.replacement"
         (Runtime.get_default_runtime_id ());
       require_registry_unpublished "offline durable save";
       let parent_sync_observed_unpublished = ref false in
       (match
          Runtime.For_testing.save_config_text_with_sync_parent
            ~runtime_config_path:path
            ~sync_parent:(fun _ ->
              parent_sync_observed_unpublished
              := (match Registry.current () with
                  | Error Registry.Registry_not_published -> true
                  | Error _ | Ok _ -> false);
              raise Injected_parent_sync_failure)
            config_b
        with
        | Error error ->
          Alcotest.(check bool)
            "offline after-rename reports durability uncertainty"
            true
            (String.starts_with
               ~prefix:
                 "runtime config replacement is visible, but parent-directory \
                  durability is unconfirmed"
               error)
        | Ok () -> Alcotest.fail "offline injected parent sync returned success");
       Alcotest.(check bool)
         "offline parent sync observes unpublished registry"
         true
         !parent_sync_observed_unpublished;
       Alcotest.(check string)
         "offline after-rename file converges to B"
         config_b
         (Fs_compat.load_file path);
       Alcotest.(check string)
         "offline after-rename cache converges to B"
         "replacement_provider.alternate"
         (Runtime.get_default_runtime_id ());
       require_registry_unpublished "offline after-rename save";
       let failed_path = Filename.concat root "before-rename-directory" in
       Unix.mkdir failed_path 0o755;
       (match Runtime.save_config_text ~runtime_config_path:failed_path config_a with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "offline before-rename failure returned success");
       Alcotest.(check string)
         "offline before-rename preserves cache B"
         "replacement_provider.alternate"
         (Runtime.get_default_runtime_id ());
       require_registry_unpublished "offline before-rename failure")
;;

let test_runtime_after_rename_converges_state () =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       with_temp_dir "exact-output-runtime-after-rename" @@ fun root ->
       let path = Filename.concat root "runtime.toml" in
       let snapshot =
         load_control_snapshot
           (Exact_output.Full_replacement
              { source = "<fixture:replacement-catalog>"
              ; contents = replacement_catalog
              })
       in
       let config_a =
         transaction_runtime_toml
           ~runtime_name:"replacement"
           ~lane_id:"transaction-a"
       in
       let config_b =
         transaction_runtime_toml
           ~runtime_name:"alternate"
           ~lane_id:"transaction-b"
       in
       (match Registry.publish ~lanes:(transaction_lanes "transaction-a") snapshot with
        | Ok _ -> ()
        | Error error ->
          Alcotest.failf
            "runtime baseline publication failed: %s"
            (Registry.publication_error_to_string error));
       (match Runtime.save_config_text ~runtime_config_path:path config_a with
        | Ok () -> ()
        | Error error -> Alcotest.failf "runtime baseline save failed: %s" error);
       let baseline = current_registry "runtime baseline registry unavailable" in
       Alcotest.(check string)
         "runtime baseline cache"
         "replacement_provider.replacement"
         (Runtime.get_default_runtime_id ());
       let parent_sync_observed_registry_fence = ref false in
       (match
          Runtime.For_testing.save_config_text_with_sync_parent
            ~runtime_config_path:path
            ~sync_parent:(fun _ ->
              parent_sync_observed_registry_fence
              := (match Registry.current () with
                  | Error Registry.Publication_busy -> true
                  | Error _ | Ok _ -> false);
              raise Injected_parent_sync_failure)
            config_b
        with
        | Error error ->
          Alcotest.(check bool)
            "after-rename failure reports durability uncertainty"
            true
            (String.starts_with
               ~prefix:
                 "runtime config replacement is visible, but parent-directory \
                  durability is unconfirmed"
               error)
        | Ok () -> Alcotest.fail "injected parent sync failure returned success");
       Alcotest.(check bool)
         "parent sync observes the private registry fence"
         true
         !parent_sync_observed_registry_fence;
       Alcotest.(check string)
         "after-rename file converges to B"
         config_b
         (Fs_compat.load_file path);
       Alcotest.(check string)
         "after-rename runtime cache converges to B"
         "replacement_provider.alternate"
         (Runtime.get_default_runtime_id ());
       let converged = current_registry "after-rename transaction fence leaked" in
       Alcotest.(check int64)
         "after-rename registry advances generation once"
         (Int64.succ (Registry.generation baseline))
         (Registry.generation converged);
       require_transaction_lane
         "after-rename registry converges to B"
         ~lane_id:"transaction-b"
         converged)
;;
