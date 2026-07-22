module Exact_output = Agent_sdk.Exact_output
module Registry = Runtime_exact_output_registry

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

let catalog_toml ~provider_id ~model_id ~target_id =
  Printf.sprintf
    {|[[providers]]
id = %S
kind = "openai_compat"
base_url = "http://127.0.0.1:1"
request_path = "/v1/chat/completions"

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
;;

let replacement_catalog =
  catalog_toml
    ~provider_id:"replacement_provider"
    ~model_id:"replacement-model"
    ~target_id:replacement_target
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

let load_control_snapshot catalog =
  let io : Exact_output.resolver_io = { getenv = (fun _ -> Ok None) } in
  match Exact_output.load_resolver_snapshot ~io ~catalog () with
  | Ok snapshot -> snapshot
  | Error _ -> Alcotest.fail "OAS control snapshot must load"
;;

let require_admitted snapshot target_id =
  match Exact_output.admit_target_ref snapshot target_id with
  | Ok target_ref ->
    Alcotest.(check string)
      "typed target admission preserves identity"
      target_id
      (Exact_output.target_ref_id target_ref)
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

let test_full_replacement_precedence ~clock ~mono_clock ~net ~proc_mgr ~fs () =
  with_temp_dir "exact-output-catalog-precedence" @@ fun root ->
  let config_root = Filename.concat root "config" in
  let base_path = Filename.concat root "workspace" in
  mkdir_p config_root;
  mkdir_p base_path;
  List.iter
    (fun name -> mkdir_p (Filename.concat config_root name))
    [ "keepers"; "personas"; "prompts" ];
  let overlay_path = Filename.concat config_root "oas-models-overlay.toml" in
  let replacement_path = Filename.concat root "replacement-models.toml" in
  let runtime_path = Filename.concat config_root "runtime.toml" in
  write_file overlay_path overlay_catalog;
  write_file replacement_path replacement_catalog;

  let overlay_snapshot =
    load_control_snapshot
      (Exact_output.Embedded_with_overlay
         { source = overlay_path; contents = overlay_catalog })
  in
  require_admitted overlay_snapshot overlay_target;
  require_admitted overlay_snapshot embedded_target;
  let replacement_snapshot =
    load_control_snapshot
      (Exact_output.Full_replacement
         { source = replacement_path; contents = replacement_catalog })
  in
  require_admitted replacement_snapshot replacement_target;
  require_not_admitted replacement_snapshot overlay_target;
  require_not_admitted replacement_snapshot embedded_target;

  Unix.putenv "MASC_CONFIG_DIR" config_root;
  Unix.putenv "OAS_MODEL_CATALOG" replacement_path;
  let create_server_state () =
    Eio.Switch.run @@ fun sw ->
    ignore
      (Server_runtime_bootstrap.create_server_state
         ~sw
         ~base_path
         ~clock
         ~mono_clock
         ~net
         ~proc_mgr
         ~fs
         ())
  in
  let require_bootstrap_rejected label target_id =
    write_file runtime_path (runtime_toml target_id);
    let rejected =
      try
        create_server_state ();
        false
      with
      | Env_config_core.Config_error _ -> true
    in
    Alcotest.(check bool) label true rejected;
    require_registry_unpublished label
  in
  require_registry_unpublished "fresh process";
  require_bootstrap_rejected "overlay target is suppressed" overlay_target;
  require_bootstrap_rejected "embedded target is suppressed" embedded_target;

  write_file runtime_path (runtime_toml replacement_target);
  create_server_state ();
  match Registry.current () with
  | Error _ -> Alcotest.fail "replacement-only target must publish the registry"
  | Ok registry ->
    let lanes : Runtime_schema.exact_output_lane_decl list =
      [ { id = "compaction_exact"; slot_ids = [ replacement_target ] } ]
    in
    let require_slots label registry =
      match Registry.lane_slots registry ~lane_id:"compaction_exact" with
      | Error error ->
        Alcotest.failf
          "%s: %s"
          label
          (Registry.lane_lookup_error_to_string error)
      | Ok slots ->
        Alcotest.(check (list string)) label [ replacement_target ] slots
    in
    require_slots "replacement-only lane" registry;
    let stable_generation = Registry.generation registry in
    let reservation =
      match Registry.prepare_replacement ~lanes with
      | Ok reservation -> reservation
      | Error error ->
        Alcotest.failf
          "same-lane reservation failed: %s"
          (Registry.publication_error_to_string error)
    in
    Registry.current () |> require_publication_busy "published registry read fence";
    Registry.prepare_replacement ~lanes
    |> require_publication_busy "published second reservation";
    Registry.publish ~lanes replacement_snapshot
    |> require_publication_busy "published direct write fence";
    (match Registry.finish_replacement reservation with
     | Ok () -> ()
     | Error error ->
       Alcotest.failf
         "same-lane reservation did not finish: %s"
         (Registry.reservation_error_to_string error));
    let after_noop =
      match Registry.current () with
      | Ok registry -> registry
      | Error error ->
        Alcotest.failf
          "same-lane finish did not republish: %s"
          (Registry.publication_error_to_string error)
    in
    Alcotest.(check int64)
      "same lanes preserve registry generation"
      stable_generation
      (Registry.generation after_noop);
    require_slots "same-lane finish preserves slots" after_noop;
    let successor =
      match Registry.prepare_replacement ~lanes with
      | Ok reservation -> reservation
      | Error error ->
        Alcotest.failf
          "successor reservation failed: %s"
          (Registry.publication_error_to_string error)
    in
    Registry.finish_replacement reservation
    |> require_reservation_inactive "stale finish";
    Registry.current () |> require_publication_busy "stale finish successor fence";
    Registry.abort_replacement reservation
    |> require_reservation_inactive "stale abort";
    Registry.current () |> require_publication_busy "stale abort successor fence";
    (match Registry.abort_replacement successor with
     | Ok () -> ()
     | Error error ->
       Alcotest.failf
         "successor reservation did not abort: %s"
         (Registry.reservation_error_to_string error));
    let after_stale_tokens =
      match Registry.current () with
      | Ok registry -> registry
      | Error error ->
        Alcotest.failf
          "successor abort did not restore the published registry: %s"
          (Registry.publication_error_to_string error)
    in
    Alcotest.(check int64)
      "stale tokens preserve registry generation"
      stable_generation
      (Registry.generation after_stale_tokens);
    require_slots "stale tokens preserve slots" after_stale_tokens;
    let stable_file = Fs_compat.load_file runtime_path in
    let stable_runtime = Runtime.get_default_runtime_id () in
    let failed_path = Filename.concat root "published-runtime-target-directory" in
    Unix.mkdir failed_path 0o755;
    (match
       Runtime.save_config_text
         ~runtime_config_path:failed_path
         failed_runtime_toml
     with
     | Error _ -> ()
     | Ok () -> Alcotest.fail "published runtime save unexpectedly replaced a directory");
    let after_failed_save =
      match Registry.current () with
      | Ok registry -> registry
      | Error error ->
        Alcotest.failf
          "failed published save left registry unavailable: %s"
          (Registry.publication_error_to_string error)
    in
    Alcotest.(check string)
      "failed published save preserves source file"
      stable_file
      (Fs_compat.load_file runtime_path);
    Alcotest.(check bool)
      "failed published save preserves target directory"
      true
      (Sys.is_directory failed_path);
    Alcotest.(check string)
      "failed published save preserves runtime cache"
      stable_runtime
      (Runtime.get_default_runtime_id ());
    Alcotest.(check int64)
      "failed published save preserves registry generation"
      stable_generation
      (Registry.generation after_failed_save);
    require_slots "failed published save preserves slots" after_failed_save
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock, mono_clock, net, _domain_mgr, proc_mgr, fs =
    Server_runtime_bootstrap.init_runtime_context env
  in
  Alcotest.run
    "Exact_output_catalog_precedence"
    [ ( "bootstrap",
        [ Alcotest.test_case
            "full replacement suppresses overlay and embedded targets"
            `Quick
            (test_full_replacement_precedence
               ~clock
               ~mono_clock
               ~net
               ~proc_mgr
               ~fs) ] ) ]
;;
