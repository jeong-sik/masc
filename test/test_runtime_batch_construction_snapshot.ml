open Alcotest
open Masc

module Catalog = Llm_provider.Model_catalog
module Declarations = Llm_provider.Catalog_snapshot
module Config = Llm_provider.Provider_config
module Caps = Llm_provider.Capabilities

type catalog = Missing | Chat of bool * float | Messages of string * float

let parsed_catalog source =
  match Catalog.of_toml_string ~source:"batch construction fixture" source with
  | Ok value -> value | Error detail -> fail detail

let catalog = function
  | Missing -> parsed_catalog ""
  | (Chat (_, price) | Messages (_, price)) as selected ->
    let kind, base, tools, thinking = match selected with
      | Chat (tools, _) -> "openai_compat", "openai_chat", tools, ""
      | Messages (policy, _) -> "anthropic", "anthropic", true,
          Printf.sprintf "anthropic_thinking_control = %S\n" policy
      | Missing -> assert false in
    parsed_catalog (Printf.sprintf {|
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

let configuration source =
  match Runtime_toml.parse_string source with
  | Ok cfg -> cfg
  | Error _ -> fail "batch construction fixture must parse"

let http_configuration path = configuration (Printf.sprintf {|
[providers.construction]
protocol = "openai-compatible-http"
endpoint = "https://construction.invalid/v1"
[providers.construction.credentials]
type = "file"
path = %S
[models.first]
api-name = "construction-model"
max-context = 8192
[models.second]
api-name = "construction-model"
max-context = 8192
[construction.first]
[construction.second]
[runtime]
default = "construction.first"
|} path)

let ordered_bindings cfg =
  List.map (fun model_id ->
    match List.find_opt (fun (binding : Runtime_schema.binding) ->
      String.equal binding.model_id model_id) cfg.Runtime_schema.bindings with
    | Some binding -> binding | None -> fail "missing fixture binding") ["first"; "second"]

let materialize cfg bindings =
  let runtimes, dropped = Runtime_instance.partition_bindings cfg bindings in
  check int "no configured binding was dropped" 0 (List.length dropped);
  check (list string) "batch preserves both binding identities and order"
    ["construction.first"; "construction.second"]
    (List.map (fun runtime -> runtime.Runtime_instance.id) runtimes);
  match List.map (fun runtime -> match runtime.Runtime_instance.execution with
    | Runtime_execution.Agent_core sealed -> Masc_test_deps.api_config sealed
    | Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
      fail "reload fixture requires HTTP bindings") runtimes with
  | [first; second] -> first, second
  | _ -> fail "reload fixture requires two materialized bindings"

let with_catalog_state run =
  let previous = Llm_provider.Catalog_snapshot.current () in
  Fun.protect ~finally:(fun () ->
    Llm_provider.Catalog_snapshot.publish previous)
    (fun () -> (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Llm_provider.Catalog_snapshot.models (Llm_provider.Catalog_snapshot.current ())) ~providers:(None))); run ())

let with_reload ~before ~after inspect = with_catalog_state (fun () ->
  let previous_fs = Fs_compat.get_fs_opt () in
  let path = Filename.temp_file "masc-batch-credential-" ".key" in
  Fun.protect ~finally:(fun () ->
    Unix.unlink path;
    match previous_fs with Some fs -> Fs_compat.set_fs fs
    | None -> Fs_compat.clear_fs ()) (fun () ->
    Unix.chmod path 0o600;
    Out_channel.with_open_bin path (fun out -> output_string out "batch-fixture-key\n");
    (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some ((catalog before))) ~providers:(None)));
    let cfg = http_configuration path in
    let bindings = ordered_bindings cfg in
    ignore (Declarations.current ());
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run (fun sw ->
        (* The child runs immediately. Its first suspension is the first
           binding's real owned File read. The queued parent replaces the
           catalog before that constructor resumes and the next binding starts.
           A pending promise says the batch has not returned, not whether the
           worker's physical read has finished. *)
        let started = ref false in
        let selected = Eio.Fiber.fork_promise ~sw (fun () ->
          started := true;
          materialize cfg bindings) in
        check bool "batch started before catalog replacement" true !started;
        check bool "batch suspended before returning" true
          (Option.is_none (Eio.Promise.peek selected));
        (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some ((catalog after))) ~providers:(None)));
        let first, second = Eio.Promise.await_exn selected in
        List.iter (fun config ->
          check string "both bindings materialized the real File credential"
            "batch-fixture-key" (config.Config.api_key :> string)) [first; second];
        let fresh = materialize cfg bindings in
        inspect (first, second) fresh))))

let tools config =
  Option.map (fun (caps : Caps.capabilities) -> caps.supports_tools)
    (Config.capabilities_for_config_model config)

let price config =
  Llm_provider.Pricing.pricing_for_model (Config.pricing_source config) "construction-model"
  |> Option.map (fun (pricing : Llm_provider.Pricing.pricing) -> pricing.input_per_million)

let check_tools expected (first, second) =
  check (option bool) "first binding uses selected capabilities" expected (tools first);
  check (option bool) "second binding shares selected capabilities" expected (tools second)

let check_price expected (first, second) =
  check (option (float 0.000001)) "first binding uses selected pricing" expected (price first);
  check (option (float 0.000001)) "second binding shares selected pricing" expected (price second)

let test_no_reload () =
  with_reload ~before:(Chat (true, 1.)) ~after:(Chat (true, 1.))
    (fun selected fresh -> List.iter (fun pair ->
      check_tools (Some true) pair; check_price (Some 1.) pair) [selected; fresh])

let test_replacement_capabilities () =
  with_reload ~before:(Chat (true, 1.)) ~after:(Chat (false, 9.))
    (fun selected fresh -> check_tools (Some true) selected; check_tools (Some false) fresh)

let test_replacement_pricing () =
  with_reload ~before:(Chat (true, 1.)) ~after:(Chat (false, 9.))
    (fun selected fresh -> check_price (Some 1.) selected; check_price (Some 9.) fresh)

let test_removal () =
  with_reload ~before:(Chat (true, 1.)) ~after:Missing
    (fun selected fresh -> check_tools (Some true) selected; check_price (Some 1.) selected;
      check_tools None fresh; check_price None fresh)

let test_captured_absence () =
  with_reload ~before:Missing ~after:(Chat (true, 9.))
    (fun selected fresh -> check_tools None selected; check_price None selected;
      check_tools (Some true) fresh; check_price (Some 9.) fresh)

let test_replacement_thinking () =
  with_reload ~before:(Messages ("adaptive_default", 1.))
    ~after:(Messages ("always_adaptive", 9.))
    (fun (first, second) (fresh_first, fresh_second) ->
      check bool "first binding uses selected thinking" true
        (Config.anthropic_thinking_control first = Some Caps.Anthropic_adaptive_default);
      check bool "second binding shares selected thinking" true
        (Config.anthropic_thinking_control second = Some Caps.Anthropic_adaptive_default);
      List.iter (fun config -> check bool "fresh batch uses replacement thinking" true
        (Config.anthropic_thinking_control config = Some Caps.Anthropic_always_adaptive))
        [fresh_first; fresh_second])

let with_rejected_http_catalog run = with_catalog_state (fun () ->
  let previous = Declarations.current () in
  let invalid = Catalog.of_toml_string ~source:"missing capability declaration"
    {|[[providers]]
id = "missing-capability-base"
kind = "openai_compat"
base_url = "https://invalid.invalid"
request_path = "/v1/chat/completions"
auth = "none"
|} in
  (match invalid with
   | Error _ -> ()
   | Ok _ -> fail "negative control requires rejected provider decoding");
  check bool "rejected input cannot replace the prior publication" true
    (Declarations.current () == previous);
  run ())

let unused_http_configuration () =
  http_configuration (Filename.concat (Filename.get_temp_dir_name ()) "masc-unused-credential.key")

let test_native_only () =
  let cfg = configuration (Printf.sprintf {|
[providers.native]
protocol = "claude-code"
command = "masc-no-spawn-fixture"
is-non-interactive = true
account-home = %S
[models.native]
api-name = "native-model"
max-context = 4096
[native.native]
|} (Filename.concat (Filename.get_temp_dir_name ()) "masc-native-home-fixture")) in
  with_rejected_http_catalog (fun () ->
    match Runtime_instance.partition_bindings cfg cfg.bindings with
    | [runtime], [] ->
      (match runtime.Runtime_instance.execution with
       | Runtime_execution.Claude_code _ -> ()
       | Agent_core _ | Codex_app_server _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
         fail "native binding changed owner")
    | _ -> fail "native-only batch must not read unused HTTP declarations")

let test_empty () =
  let cfg = unused_http_configuration () in
  with_rejected_http_catalog (fun () ->
    let runtimes, dropped = Runtime_instance.partition_bindings cfg [] in
    check int "empty batch has no runtimes" 0 (List.length runtimes);
    check int "empty batch has no drops" 0 (List.length dropped))

let test_disabled_binding () =
  let cfg = unused_http_configuration () in
  let original = List.hd (ordered_bindings cfg) in
  let binding = {original with Runtime_schema.enabled=false} in
  with_rejected_http_catalog (fun () ->
    match Runtime_instance.partition_bindings cfg [binding] with
    | [], [_, Runtime_config_error.Binding_disabled] -> ()
    | _ -> fail "disabled binding must retain its drop reason without HTTP lookup")

let test_disabled_provider () =
  let cfg = unused_http_configuration () in
  let cfg = {cfg with Runtime_schema.providers=List.map
      (fun (provider : Runtime_schema.provider) -> {provider with enabled=false}) cfg.providers} in
  with_rejected_http_catalog (fun () ->
    match Runtime_instance.partition_bindings cfg [List.hd (ordered_bindings cfg)] with
    | [], [_, Runtime_config_error.Provider_disabled "construction"] -> ()
    | _ -> fail "disabled provider must retain its drop reason without HTTP lookup")

let test_unresolved ~provider () =
  let cfg = unused_http_configuration () in
  let original = List.hd (ordered_bindings cfg) in
  let binding = if provider then {original with Runtime_schema.provider_id="missing-provider"}
    else {original with Runtime_schema.model_id="missing-model"} in
  with_rejected_http_catalog (fun () ->
    match provider, Runtime_instance.partition_bindings cfg [binding] with
    | true, ([], [_, Runtime_config_error.Provider_not_declared "missing-provider"])
    | false, ([], [_, Runtime_config_error.Model_not_declared "missing-model"]) -> ()
    | _ -> fail "unresolved binding must retain its typed drop without HTTP lookup")

let () = run "runtime batch construction snapshot"
  ["batch", [
    test_case "no reload retains both binding policies" `Quick test_no_reload;
    test_case "replacement retains both capabilities" `Quick test_replacement_capabilities;
    test_case "replacement retains both prices" `Quick test_replacement_pricing;
    test_case "removal retains both provider policies" `Quick test_removal;
    test_case "later provider does not fill either absence" `Quick test_captured_absence;
    test_case "replacement retains both thinking controls" `Quick test_replacement_thinking];
   "unused HTTP catalog", [
    test_case "native-only batch keeps native ownership" `Quick test_native_only;
    test_case "empty batch remains empty" `Quick test_empty;
    test_case "disabled binding keeps typed drop" `Quick test_disabled_binding;
    test_case "disabled provider keeps typed drop" `Quick test_disabled_provider;
    test_case "missing provider keeps typed drop" `Quick (test_unresolved ~provider:true);
    test_case "missing model keeps typed drop" `Quick (test_unresolved ~provider:false)]]
