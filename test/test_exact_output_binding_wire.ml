(* One provider row, two wires. ollama_cloud declares
   [identity_kinds = ["ollama"; "openai_compat"]], so the row alone cannot say
   which surface a deployment reaches — only its binding can. The exact-output
   slot used to read the row and ran on the native /api/chat surface while the
   same binding's Keeper requests ran on the OpenAI-compatible one, which is
   what refused the Librarian's first slot on every run from 2026-09-19
   (#37674). These cases declare the same model twice, once per protocol, and
   watch the two go to different wires. *)
open Alcotest
open Masc
module EO = Agent_core.Exact_output
module Resolver = Llm_provider.Exact_output_resolver
module PC = Llm_provider.Provider_config
module Registry = Runtime_exact_output_registry

let lane_id = "librarian_exact"
let messages = [ Agent_core.Types.user_msg "Return one JSON object." ]

let requirement =
  EO.make_output_requirement
    ~schema:(`Assoc [ "type", `String "object" ])
    ~minimum_guarantee:EO.Json_syntax
;;

let require_ok label = function
  | Ok value -> value
  | Error _ -> fail label
;;

(* The live shape of the binding this defect was found on: the Librarian's
   cheap HTTP slot, whose model row names an effort its wire has to accept. *)
let runtime_toml ~protocol ~endpoint =
  Printf.sprintf
    {|[runtime]
default = "ollama_cloud.deepseek-flash"
%s
[providers.ollama_cloud]
protocol = %S
endpoint = %S
connect-timeout-s = 180.0
[providers.ollama_cloud.credentials]
type = "env"
key = "OLLAMA_CLOUD_API_KEY"
[models.deepseek-flash]
api-name = "deepseek-v4.1-flash"
tools-support = true
thinking-support = true
reasoning-effort = "low"
[ollama_cloud.deepseek-flash]
|}
    (String.concat
       "\n"
       (List.map
          (fun lane ->
             Printf.sprintf
               "[runtime.exact_output_lanes.%s]\nslots = [\"ollama_cloud.deepseek-flash\"]"
               lane)
          (List.sort_uniq
             String.compare
             (lane_id :: Server_runtime_bootstrap.mandatory_exact_output_lane_ids))))
    protocol
    endpoint
;;

let with_runtime f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OLLAMA_CLOUD_API_KEY" (Some "synthetic-no-network")
  @@ fun () ->
  let root = Filename.temp_dir "exact-binding-wire-" "" in
  let previous_runtime = Runtime.For_testing.snapshot () in
  let previous_startup = Runtime_startup_state.get () in
  let previous_catalog = Llm_provider.Model_catalog.global () in
  Fun.protect
    ~finally:(fun () ->
      Registry.unpublish () |> require_ok "unpublish fixture registry";
      Runtime.For_testing.restore previous_runtime;
      Runtime_startup_state.set previous_startup;
      (match previous_catalog with
       | None -> Llm_provider.Model_catalog.clear_global ()
       | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
      Fs_compat.remove_tree root)
    (fun () ->
       Llm_provider.Model_catalog.clear_global ();
       let load ~protocol ~endpoint =
         let path = Filename.concat root "runtime.toml" in
         Fs_compat.save_file path (runtime_toml ~protocol ~endpoint);
         Runtime.init_default ~config_path:path |> require_ok "runtime initialization";
         let keeper_config =
           match Runtime.get_runtimes () with
           | [ runtime ] ->
             (match runtime.Runtime.execution with
              | Runtime_execution.Agent_core config -> config
              | Runtime_execution.Codex_app_server _
              | Runtime_execution.Claude_code _
              | Runtime_execution.Antigravity_cli _ -> fail "expected the HTTP runtime")
           | _ -> fail "expected one runtime"
         in
         Server_runtime_bootstrap.For_testing.configure_exact_output_registry
           ~config_root:root
           ();
         let registry = Registry.current () |> require_ok "published registry" in
         let admitted =
           match Registry.resolve_lane registry ~lane_id with
           | Ok { selected_slots = [ slot ]; _ } -> slot.admitted_target
           | Ok _ | Error _ -> fail "expected one admitted Librarian slot"
         in
         keeper_config, admitted
       in
       f load)
;;

let check_wire label ~(keeper : PC.t) ~(exact : PC.t) =
  check
    string
    (label ^ ": the exact slot speaks the Keeper's wire")
    (PC.string_of_provider_kind keeper.kind)
    (PC.string_of_provider_kind exact.kind);
  check string (label ^ ": same endpoint") keeper.base_url exact.base_url;
  check string (label ^ ": same request path") keeper.request_path exact.request_path
;;

(* The OpenAI-compatible binding: ollama.com/v1 takes the categorical effort
   this row declares, so the slot both matches its Keeper's wire and passes the
   preflight the native surface refused. *)
let test_openai_compatible_binding_reaches_its_own_wire () =
  with_runtime
  @@ fun load ->
  let keeper, admitted =
    load ~protocol:"openai-compatible-http" ~endpoint:"https://ollama.com/v1"
  in
  let projected = Resolver.projection_target admitted in
  check_wire "openai-compatible" ~keeper ~exact:projected.config;
  check
    string
    "the binding's wire is the OpenAI-compatible one"
    "openai_compat"
    (PC.string_of_provider_kind projected.config.kind);
  check
    bool
    "the declared effort is admitted on that wire"
    true
    (List.mem
       Llm_provider.Reasoning_effort.Low
       (Option.value
          projected.capabilities.Llm_provider.Capabilities.accepted_reasoning_efforts
          ~default:[]));
  match EO.project_request_body ~target:admitted ~messages requirement with
  | Ok (_ : EO.request_body_projection) -> ()
  | Error error -> failf "exact projection refused: %s" (EO.admission_error_reason error)
;;

(* The native binding of the same model. Its wire has no categorical effort
   ladder, so the same declared effort cannot be sent and the slot is refused
   before dispatch -- the outcome the OpenAI-compatible binding above must not
   inherit. *)
let test_native_binding_reaches_the_native_wire () =
  with_runtime
  @@ fun load ->
  let keeper, admitted = load ~protocol:"ollama-http" ~endpoint:"https://ollama.com" in
  let projected = Resolver.projection_target admitted in
  check_wire "native" ~keeper ~exact:projected.config;
  check
    string
    "the binding's wire is the native one"
    "ollama"
    (PC.string_of_provider_kind projected.config.kind);
  check string "the native surface" "/api/chat" projected.config.request_path;
  match EO.project_request_body ~target:admitted ~messages requirement with
  | Ok (_ : EO.request_body_projection) ->
    fail "the native wire has no effort ladder, so this request cannot be built"
  | Error error ->
    Printf.eprintf "native wire refusal: %s\n%!" (EO.admission_error_reason error)
;;

let () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs
  @@ fun () ->
  run
    "Exact binding wire"
    [ ( "wire"
      , [ test_case
            "an OpenAI-compatible binding runs its exact slot on that wire"
            `Quick
            test_openai_compatible_binding_reaches_its_own_wire
        ; test_case
            "a native binding of the same model runs on the native wire"
            `Quick
            test_native_binding_reaches_the_native_wire
        ] )
    ]
;;
