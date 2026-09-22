(* One provider row, two wires. ollama_cloud declares
   [identity_kinds = ["ollama"; "openai_compat"]], so the row alone cannot say
   which surface a deployment reaches — only its binding can. The exact-output
   slot used to read the row and ran on the native /api/chat surface while the
   same binding's Keeper requests ran on the OpenAI-compatible one, which is
   what refused the Librarian's first slot on every run from 2026-09-19
   (#37674). These cases declare the same model once per protocol, and once
   per reasoning stance, and watch where each one lands. *)
open Alcotest
open Masc
module EO = Agent_core.Exact_output
module Resolver = Llm_provider.Exact_output_resolver
module Plan = Llm_provider.Exact_output_plan
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
   cheap HTTP slot. [stance] is how its model row answers a wire that turns
   reasoning on by itself — the two answers such a wire accepts. *)
let runtime_toml ~protocol ~endpoint ~stance =
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
%s
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
    stance
;;

(* A named depth, plus the capability block every slot in the shipped seed
   carries — which is what makes the binding hold a capability override, the
   branch a deployment actually takes. *)
let declared_effort =
  {|reasoning-effort = "low"
[models.deepseek-flash.capabilities]
thinking-control-format = "reasoning-effort"|}
;;

(* The other answer, and the one the rest of the seed's ollama_cloud rows
   give: no depth named, the provider's own default carries the request. The
   pairing is the seed's own (config/runtime.toml [models.deepseek-v4-flash]):
   a row that states this stance also states that its request axis carries no
   thinking control, because the effort field is the only one this wire has
   and the row is declining to use it. *)
let rides_provider_default =
  {|reasoning-uncontrolled = true
[models.deepseek-flash.capabilities]
thinking-control-format = "none"|}
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
       let load ~protocol ~endpoint ~stance =
         let path = Filename.concat root "runtime.toml" in
         Fs_compat.save_file path (runtime_toml ~protocol ~endpoint ~stance);
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

(* The frozen exact target for this binding, read through the resolver's own
   types so the wire and the typed preflight verdict are both visible. The
   slot declaration is the one the server builds at boot
   ([Server_runtime_bootstrap.exact_output_targets_of_runtimes]): the binding,
   carrying the thinking support its model row declares. *)
let exact_view (keeper : PC.t) =
  let declared : Resolver.declared_target =
    { target_ref = "ollama_cloud.deepseek-flash"
    ; binding = { keeper with PC.enable_thinking = Some true }
    ; credential = Resolver.Credential_resolved keeper.PC.api_key
    ; body_timeout_s = None
    }
  in
  let snapshot =
    Resolver.load_resolver_snapshot
      ~io:{ getenv = (fun _ -> Ok (Some "synthetic-no-network")) }
      ~catalog:(Resolver.Embedded_with_targets [ declared ])
      ()
    |> require_ok "resolver snapshot"
  in
  Resolver.admit_target_ref snapshot declared.target_ref
  |> require_ok "admitted target"
  |> Resolver.projection_target
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

let preflight (projected : Resolver.projection_target) =
  Plan.preflight
    ~config:projected.config
    ~messages
    ~body_timeout_s:projected.body_timeout_s
    ~anthropic_thinking_control:projected.anthropic_thinking_control
;;

(* ollama.com/v1 takes the categorical effort this row declares, so the slot
   both matches its Keeper's wire and passes the preflight the native surface
   refuses. *)
let test_openai_compatible_binding_reaches_its_own_wire () =
  with_runtime
  @@ fun load ->
  let keeper, admitted =
    load
      ~protocol:"openai-compatible-http"
      ~endpoint:"https://ollama.com/v1"
      ~stance:declared_effort
  in
  let projected = exact_view keeper in
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
  (match preflight projected with
   | Ok _ -> ()
   | Error _ -> fail "the compatible wire should build this request");
  match EO.project_request_body ~target:admitted ~messages requirement with
  | Ok (_ : EO.request_body_projection) -> ()
  | Error error -> failf "exact projection refused: %s" (EO.admission_error_reason error)
;;

(* The native binding of the same model. Its wire carries the thinking state
   in a control with no effort ladder, so the same declared effort cannot be
   sent and the slot is refused before dispatch — the outcome the
   OpenAI-compatible binding above must not inherit. *)
let test_native_binding_reaches_the_native_wire () =
  with_runtime
  @@ fun load ->
  let keeper, admitted =
    load ~protocol:"ollama-http" ~endpoint:"https://ollama.com" ~stance:declared_effort
  in
  let projected = exact_view keeper in
  check_wire "native" ~keeper ~exact:projected.config;
  check
    string
    "the binding's wire is the native one"
    "ollama"
    (PC.string_of_provider_kind projected.config.kind);
  check string "the native surface" "/api/chat" projected.config.request_path;
  (match preflight projected with
   | Error (Plan.Provider_request_rejected (Llm_provider.Http_client.AcceptRejected _)) ->
     ()
   | Error _ -> fail "the native wire should refuse the request itself"
   | Ok _ ->
     fail "the native wire has no effort ladder, so this request cannot be built");
  match EO.project_request_body ~target:admitted ~messages requirement with
  | Ok (_ : EO.request_body_projection) ->
    fail "the native wire has no effort ladder, so this request cannot be built"
  | Error error ->
    Printf.eprintf "native wire refusal: %s\n%!" (EO.admission_error_reason error)
;;

(* The rows that ride the provider's default instead of naming a depth. The
   OpenAI-compatible wire turns reasoning on when a request carries no
   control, so it takes this stance as the answer — but only if the stance
   survives the trip from the binding into the exact request (#37674). *)
let test_a_row_that_rides_the_provider_default_still_projects () =
  with_runtime
  @@ fun load ->
  let keeper, admitted =
    load
      ~protocol:"openai-compatible-http"
      ~endpoint:"https://ollama.com/v1"
      ~stance:rides_provider_default
  in
  let projected = exact_view keeper in
  check_wire "rides-provider-default" ~keeper ~exact:projected.config;
  check
    bool
    "the binding's reasoning stance reaches the exact request"
    true
    projected.config.reasoning_uncontrolled;
  (match preflight projected with
   | Ok _ -> ()
   | Error _ -> fail "a stated stance is an answer this wire accepts");
  match EO.project_request_body ~target:admitted ~messages requirement with
  | Ok (_ : EO.request_body_projection) -> ()
  | Error error -> failf "exact projection refused: %s" (EO.admission_error_reason error)
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
        ; test_case
            "a row that rides the provider's reasoning default still projects"
            `Quick
            test_a_row_that_rides_the_provider_default_still_projects
        ] )
    ]
;;
