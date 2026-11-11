open Alcotest
open Masc

module Catalog = Llm_provider.Model_catalog
module Config = Llm_provider.Provider_config
module Caps = Llm_provider.Capabilities

type catalog = Missing | Chat of bool * float | Messages of string * float

let catalog selected =
  let result = match selected with
  | Missing -> Catalog.of_toml_string ~source:"construction fixture" ""
  | (Chat (_, price) | Messages (_, price)) as selected ->
    let kind, base, tools, thinking = match selected with
      | Chat (tools, _) -> "openai_compat", "openai_chat", tools, ""
      | Messages (policy, _) -> "anthropic", "anthropic", true,
          Printf.sprintf "anthropic_thinking_control = %S\n" policy
      | Missing -> assert false in
    Catalog.of_toml_string ~source:"construction fixture"
      (Printf.sprintf {|
[[providers]]
id = "construction"
kind = %S
base_url = "https://construction.invalid/v1"
request_path = "/v1/chat/completions"
auth = "api-key"
capabilities_base = %S
[[models]]
model_id = "construction-model"
provider_name = "construction"
max_context_tokens = 2048
supports_tools = %b
input_per_million = %.1f
output_per_million = %.1f
%s|} kind base tools price (price *. 2.) thinking)
  in
  match result with Ok value -> value | Error detail -> fail detail

let materialize cfg binding =
  match Runtime_instance.of_binding cfg binding with
  | Ok runtime ->
    (match runtime.Runtime_instance.execution with
     | Runtime_execution.Agent_core sealed -> Masc_test_deps.api_config sealed
     | Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
       fail "fixture requires an HTTP execution")
  | Error reason -> fail (Runtime_config_error.string_of_drop_reason reason)

let configuration path =
  let source = Printf.sprintf {|
[providers.construction]
protocol = "openai-compatible-http"
endpoint = "https://construction.invalid/v1"
[providers.construction.credentials]
type = "file"
path = %S
[models.selected]
api-name = "construction-model"
max-context = 8192
[construction.selected]
[runtime]
default = "construction.selected"
|} path in
  match Runtime_toml.parse_string source with
  | Error _ -> fail "construction fixture must parse"
  | Ok cfg ->
    match cfg.Runtime_schema.bindings with
    | [binding] -> cfg, binding
    | _ -> fail "construction fixture requires exactly one binding"

let with_reload ~before ~after inspect =
  let previous = Llm_provider.Catalog_snapshot.current () in
  let previous_fs = Fs_compat.get_fs_opt () in
  let path = Filename.temp_file "masc-construction-credential-" ".key" in
  Fun.protect
    ~finally:(fun () ->
      Unix.unlink path;
      Llm_provider.Catalog_snapshot.publish previous;
      match previous_fs with Some fs -> Fs_compat.set_fs fs
      | None -> Fs_compat.clear_fs ())
    (fun () ->
      Unix.chmod path 0o600;
      Out_channel.with_open_bin path (fun out ->
        output_string out "construction-fixture-key\n");
      (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some ((catalog before))) ~providers:(None)));
      let cfg, binding = configuration path in
      (* Warm the immutable declarations before forking. Every operation in
         the constructor before the owned File read is synchronous. Fork runs
         the child immediately; its first suspension is that real systhread
         read, leaving the parent ahead of the completion in the run queue.
         No sleep, retry, production hook or special credential file is used. *)
      ignore (Llm_provider.Catalog_snapshot.current ());
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Eio.Switch.run (fun sw ->
          let started = ref false in
          let selected = Eio.Fiber.fork_promise ~sw (fun () ->
            started := true;
            materialize cfg binding) in
          check bool "construction started before catalog reload" true !started;
          check bool "File materialization suspended before returning" true
            (Option.is_none (Eio.Promise.peek selected));
          (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some ((catalog after))) ~providers:(None)));
          let selected = Eio.Promise.await_exn selected in
          check string "the real owned File credential was materialized"
            "construction-fixture-key" (selected.Config.api_key :> string);
          let fresh = materialize cfg binding in
          inspect selected fresh)))

let capabilities config = Config.capabilities_for_config_model config

let tools config = Option.map (fun (caps : Caps.capabilities) -> caps.supports_tools)
    (capabilities config)

let price config =
  Llm_provider.Pricing.pricing_for_model (Config.pricing_source config)
    "construction-model"
  |> Option.map (fun (pricing : Llm_provider.Pricing.pricing) -> pricing.input_per_million)

let check_tools expected config =
  check (option bool) "selected tools policy" expected (tools config)

let check_price expected config =
  check (option (float 0.000001)) "selected input price" expected (price config)

let test_no_reload () =
  with_reload ~before:(Chat (true, 1.)) ~after:(Chat (true, 1.))
    (fun selected fresh ->
      List.iter (fun config -> check_tools (Some true) config;
        check_price (Some 1.) config;
        check (option int) "same catalog context ceiling" (Some 2048) config.Config.max_context)
        [selected; fresh])

let test_replaced_capabilities () =
  with_reload ~before:(Chat (true, 1.)) ~after:(Chat (false, 9.))
    (fun selected fresh -> check_tools (Some true) selected; check_tools (Some false) fresh)

let test_replaced_pricing () =
  with_reload ~before:(Chat (true, 1.)) ~after:(Chat (false, 9.))
    (fun selected fresh -> check_price (Some 1.) selected; check_price (Some 9.) fresh)

let test_removed_provider () =
  with_reload ~before:(Chat (true, 1.)) ~after:Missing
    (fun selected fresh ->
      check_tools (Some true) selected; check_price (Some 1.) selected;
      check_tools None fresh; check_price None fresh)

let test_captured_absence () =
  with_reload ~before:Missing ~after:(Chat (true, 9.))
    (fun selected fresh ->
      check_tools None selected; check_price None selected;
      check_tools (Some true) fresh; check_price (Some 9.) fresh)

let test_replaced_thinking () =
  with_reload ~before:(Messages ("adaptive_default", 1.))
    ~after:(Messages ("always_adaptive", 9.))
    (fun selected fresh ->
      check bool "selected Anthropic thinking policy" true
        (Config.anthropic_thinking_control selected = Some Caps.Anthropic_adaptive_default);
      check bool "fresh Anthropic thinking policy" true
        (Config.anthropic_thinking_control fresh = Some Caps.Anthropic_always_adaptive))

let () =
  run "runtime construction snapshot"
    ["construction", [
      test_case "no reload retains policy and credential" `Quick test_no_reload;
      test_case "replacement retains selected capabilities" `Quick test_replaced_capabilities;
      test_case "replacement retains selected pricing" `Quick test_replaced_pricing;
      test_case "removal retains selected provider policy" `Quick test_removed_provider;
      test_case "later provider does not fill captured absence" `Quick test_captured_absence;
      test_case "replacement retains selected thinking policy" `Quick test_replaced_thinking;
    ]]
