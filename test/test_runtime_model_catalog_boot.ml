(* A standalone executable reads runtime.toml against the catalog the operator
   named in AGENT_CORE_MODEL_CATALOG (#49351). The table below declares an
   effort only the named catalog's row accepts, so the same table is refused
   against the embedded catalog and loads against the named one. *)
open Alcotest
open Masc

module Boot = Runtime_model_catalog_boot
module Snapshot = Llm_provider.Catalog_snapshot

let catalog_env_key = "AGENT_CORE_MODEL_CATALOG"

let operator_catalog =
  {|
[[providers]]
capabilities_base = "openai_chat"
id = "standalone_boot"
kind = "openai_compat"
base_url = "https://standalone-boot.invalid/v1"
request_path = "/chat/completions"
auth = "none"

[[models]]
model_id = "ladder-model"
provider_name = "standalone_boot"
base = "openai_chat"
max_context_tokens = 131072
max_output_tokens = 65536
supports_tools = true
supports_reasoning = true
accepted_reasoning_efforts = ["low", "medium", "high"]
thinking_control_format = "reasoning_effort"
supports_system_prompt = true
|}

let runtime_table =
  {|
[runtime]
default = "standalone_boot.ladder"

[providers.standalone_boot]
display-name = "Standalone boot fixture"
protocol = "openai-compatible-http"
endpoint = "https://standalone-boot.invalid/v1"

[models.ladder]
api-name = "ladder-model"
max-context = 128000
tools-support = true
thinking-support = true
reasoning-effort = "low"
streaming = true

[standalone_boot.ladder]
is-default = true
max-concurrent = 1
|}

let write_file path content =
  Out_channel.with_open_bin path (fun out -> output_string out content)

let with_fixture f =
  let dir = Filename.temp_file "masc-catalog-boot-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let catalog_path = Filename.concat dir "operator-models.toml" in
  let config_path = Filename.concat dir "runtime.toml" in
  let previous_catalog = Snapshot.current () in
  let previous_runtime = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore previous_runtime;
      Snapshot.publish previous_catalog;
      List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
        [ catalog_path; config_path ];
      Unix.rmdir dir)
    (fun () ->
      write_file catalog_path operator_catalog;
      write_file config_path runtime_table;
      f ~catalog_path ~config_path)

let with_catalog_env value f =
  Masc_test_deps.with_process_env catalog_env_key value f

let carries_ladder_model () =
  Option.is_some (Snapshot.find (Snapshot.current ()) "standalone_boot")

let require_ok label = function
  | Ok value -> value
  | Error detail -> failf "%s: %s" label detail

let test_embedded_catalog_refuses_the_table () =
  with_fixture @@ fun ~catalog_path:_ ~config_path ->
  with_catalog_env None @@ fun () ->
  match Boot.init_standalone ~gate:Routing_only ~config_path with
  | Ok () -> fail "the embedded catalog accepted an effort it does not declare"
  | Error _ -> check bool "the embedded catalog stays selected" false (carries_ladder_model ())

let test_init_reads_the_named_catalog gate () =
  with_fixture @@ fun ~catalog_path ~config_path ->
  with_catalog_env (Some catalog_path) @@ fun () ->
  Boot.init_standalone ~gate ~config_path |> require_ok "standalone init";
  check bool "the named catalog is the selected one" true (carries_ladder_model ());
  check (list string) "the table is the active one" [ "standalone_boot.ladder" ]
    (Runtime.get_runtime_ids ())

let test_observation_reads_the_named_catalog () =
  with_fixture @@ fun ~catalog_path ~config_path ->
  with_catalog_env (Some catalog_path) @@ fun () ->
  let observation =
    Boot.load_standalone_config_observation ~runtime_config_path:config_path
    |> require_ok "standalone observation"
  in
  match Runtime.init_default_degraded_observation observation with
  | Ok Runtime.Initialized -> ()
  | Ok (Runtime.Initialized_degraded _) ->
    fail "a runtime the named catalog carries was disabled"
  | Error error -> fail (Runtime.strict_init_error_to_string error)

let test_list_reads_the_named_catalog () =
  with_fixture @@ fun ~catalog_path ~config_path ->
  with_catalog_env (Some catalog_path) @@ fun () ->
  let runtimes, _, _, _, _ =
    Boot.load_standalone_list ~config_path |> require_ok "standalone list"
  in
  check (list string) "the listed runtimes" [ "standalone_boot.ladder" ]
    (List.map (fun (runtime : Runtime_instance.t) -> runtime.id) runtimes)

(* A named catalog that does not load is an error that names the file. The
   embedded catalog would refuse this table for another reason, so falling
   back to it would hide which file the operator has to repair. *)
let test_unreadable_named_catalog_is_an_error () =
  with_fixture @@ fun ~catalog_path ~config_path ->
  let missing = catalog_path ^ ".absent" in
  with_catalog_env (Some missing) @@ fun () ->
  let previous = Snapshot.current () in
  let refused label = function
    | Ok _ -> failf "%s read the table without the named catalog" label
    | Error detail ->
      check bool (label ^ " names the catalog file") true
        (String_util.contains_substring detail missing)
  in
  refused "init" (Boot.init_standalone ~gate:Routing_only ~config_path);
  refused "strict init" (Boot.init_standalone ~gate:Catalog_required ~config_path);
  refused "observation"
    (Boot.load_standalone_config_observation ~runtime_config_path:config_path);
  refused "list" (Boot.load_standalone_list ~config_path);
  check bool "the previous selection is kept" true (Snapshot.current () == previous)

let () =
  run "runtime_model_catalog_boot"
    [ ( "standalone"
      , [ test_case "embedded catalog refuses the table" `Quick
            test_embedded_catalog_refuses_the_table
        ; test_case "routing-only init reads the named catalog" `Quick
            (test_init_reads_the_named_catalog Routing_only)
        ; test_case "catalog-required init reads the named catalog" `Quick
            (test_init_reads_the_named_catalog Catalog_required)
        ; test_case "observation reads the named catalog" `Quick
            test_observation_reads_the_named_catalog
        ; test_case "list reads the named catalog" `Quick
            test_list_reads_the_named_catalog
        ; test_case "unreadable named catalog is an error" `Quick
            test_unreadable_named_catalog_is_an_error
        ] )
    ]
