open Alcotest
open Masc
module EO = Agent_core.Exact_output
module Resolver = Llm_provider.Exact_output_resolver
module Plan = Llm_provider.Exact_output_plan
module Registry = Runtime_exact_output_registry

let messages = [ Agent_core.Types.user_msg "Return one JSON object." ]
let requirement = EO.make_output_requirement
    ~schema:(`Assoc [ "type", `String "object" ]) ~minimum_guarantee:EO.Json_syntax

let require_ok label = function Ok x -> x | Error _ -> fail label

let openrouter_binding ?reasoning_effort () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~provider_id:"openrouter"
    ~model_id:"z-ai/glm-5.3-flash"
    ~base_url:"https://openrouter.ai/api/v1"
    ~request_path:"/chat/completions"
    ~enable_thinking:true
    ?reasoning_effort
    ~connect_timeout_s:180.
    ()

let test_missing_effort_has_typed_request_rejection () =
  let target : Resolver.declared_target =
    { target_ref = "openrouter.probe"
    ; binding = openrouter_binding ()
    ; credential = Resolver.Credential_not_declared
    ; body_timeout_s = None } in
  let snapshot = Resolver.load_resolver_snapshot
      ~io:{ getenv = (fun _ -> Ok None) }
      ~catalog:(Resolver.Embedded_with_targets [ target ]) ()
    |> require_ok "resolver snapshot" in
  let admitted = Resolver.admit_target_ref snapshot target.target_ref
    |> require_ok "admitted target" in
  let projected = Resolver.projection_target admitted in
  (match Llm_provider.Complete_common.thinking_control_request_rejection
      ~caps:projected.capabilities projected.config with
   | Some Llm_provider.Complete_common.Enable_not_encodable ->
     Printf.eprintf "typed request control: Enable_not_encodable\n%!"
   | _ -> fail "missing effort had a different typed rejection");
  match Plan.preflight ~config:projected.config ~messages
      ~body_timeout_s:projected.body_timeout_s
      ~anthropic_thinking_control:projected.anthropic_thinking_control with
  | Error (Plan.Provider_request_rejected (Llm_provider.Http_client.AcceptRejected { reason })) ->
    Printf.eprintf "typed preflight: Provider_request_rejected(AcceptRejected): %s\n%!" reason
  | Error _ -> fail "missing effort had a different plan rejection"
  | Ok _ -> fail "missing effort unexpectedly reached a plan"

let runtime_toml effort = Printf.sprintf {|[runtime]
default = "openrouter.probe"
[runtime.exact_output_lanes.librarian_exact]
slots = ["openrouter.probe"]
max_output_tokens = 4096
[runtime.exact_output_lanes.hitl_auto_judge]
slots = ["openrouter.probe"]
max_output_tokens = 4096
[runtime.exact_output_lanes.board_attention_exact]
slots = ["openrouter.probe"]
max_output_tokens = 4096
[providers.openrouter]
protocol = "openai-compatible-http"
endpoint = "https://openrouter.ai/api/v1"
connect-timeout-s = 180.0
[providers.openrouter.credentials]
type = "env"
key = "OPENROUTER_API_KEY"
[models.probe]
api-name = "z-ai/glm-5.3-flash"
tools-support = true
thinking-support = true
max-output-tokens = 384000
reasoning-effort = %S
[openrouter.probe]
|} effort

let with_runtime f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OPENROUTER_API_KEY" (Some "synthetic-no-network") @@ fun () ->
  let root = Filename.temp_dir "exact-runtime-reasoning-" "" in
  let previous_runtime = Runtime.For_testing.snapshot () in
  let previous_startup = Runtime_startup_state.get () in
  let previous_catalog = Llm_provider.Model_catalog.global () in
  Fun.protect ~finally:(fun () ->
    Registry.unpublish () |> require_ok "unpublish fixture registry";
    Runtime.For_testing.restore previous_runtime;
    Runtime_startup_state.set previous_startup;
    (match previous_catalog with
     | None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    Fs_compat.remove_tree root) @@ fun () ->
  Llm_provider.Model_catalog.clear_global ();
  let load effort =
    let path = Filename.concat root "runtime.toml" in
    Fs_compat.save_file path (runtime_toml effort);
    Runtime.init_default ~config_path:path |> require_ok "runtime initialization";
    let runtime = match Runtime.get_runtimes () with
      | [ runtime ] -> runtime | _ -> fail "expected one runtime" in
    (match runtime.Runtime.execution with
     | Runtime_execution.Agent_core config ->
       check (option string) "ordinary runtime retains its declared effort" (Some effort)
         (Option.map Llm_provider.Reasoning_effort.to_string config.reasoning_effort)
     | _ -> fail "expected the API runtime");
    Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ();
    let registry = Registry.current () |> require_ok "published registry" in
    match Registry.resolve_lane registry ~lane_id:"librarian_exact" with
    | Ok { selected_slots = [ slot ]; _ } -> slot.admitted_target
    | _ -> fail "expected one admitted Librarian slot" in
  f load

let ready target =
  (match EO.project_request_body ~target ~messages requirement with
   | Ok _ -> ()
   | Error error -> failf "actual Exact projection: %s" (EO.admission_error_reason error));
  let selected = EO.resolve_target target |> require_ok "resolve frozen credential" in
  match EO.admit ~target:selected ~messages requirement with
  | Ok plan -> plan
  | Error error -> failf "actual Exact admission: %s" (EO.admission_error_reason error)

let test_runtime_effort_reaches_exact_preflight () =
  with_runtime @@ fun load ->
  ignore (ready (load "low") : EO.ready_plan)

let test_effort_changes_frozen_exact_identity () =
  with_runtime @@ fun load ->
  let low = load "low" in
  let low_plan = ready low in
  let high = load "high" in
  let high_plan = ready high in
  let generation plan = EO.plan_provenance plan |> EO.plan_provenance_catalog_generation
    |> EO.catalog_generation_fingerprint in
  let identity plan = EO.plan_provenance plan |> EO.plan_provenance_target_identity
    |> EO.target_identity_fingerprint in
  let evidence plan = EO.plan_provenance plan |> EO.plan_provenance_catalog_evidence
    |> EO.catalog_evidence_sha256 in
  check bool "effort changes catalog generation" true (generation low_plan <> generation high_plan);
  check bool "effort changes catalog evidence" true (evidence low_plan <> evidence high_plan);
  check bool "effort changes target identity" true (identity low_plan <> identity high_plan);
  check bool "effort changes frozen request plan" true
    (EO.plan_fingerprint low_plan <> EO.plan_fingerprint high_plan);
  check string "republishing high leaves the captured low plan unchanged"
    (EO.plan_fingerprint low_plan) (EO.plan_fingerprint (ready low))

let test_explicit_effort_reaches_serialized_request () =
  let module Ready = Llm_provider.Exact_output_ready_admission in
  with_runtime @@ fun load ->
  List.iter (fun effort ->
    let runtime_plan = ready (load (Llm_provider.Reasoning_effort.to_string effort)) in
    let runtime_receipt = EO.start_attempt runtime_plan
      |> require_ok "runtime attempt" |> EO.attempt_receipt in
    let target : Resolver.declared_target =
      { target_ref = "openrouter.probe"
      ; binding = openrouter_binding ~reasoning_effort:effort ()
      ; credential =
          Resolver.Credential_resolved (Llm_provider.Secret.of_string "synthetic-no-network")
      ; body_timeout_s = None } in
    let snapshot = Resolver.load_resolver_snapshot
        ~io:{ getenv = (fun _ -> Ok (Some "synthetic-no-network")) }
        ~catalog:(Resolver.Embedded_with_targets [ target ]) ()
      |> require_ok "wire resolver snapshot" in
    let selected =
      Resolver.admit_target_ref snapshot target.target_ref
      |> require_ok "wire admitted target"
      (* The runtime bootstrap runs this target through a lane that declares
         [max_output_tokens = 4096]; the wire plan must carry the same budget
         or the frozen bytes differ for a reason the test is not about. *)
      |> fun admitted -> Resolver.admitted_target_with_max_tokens admitted 4096
      |> Resolver.resolve_target
      |> require_ok "wire selected target"
    in
    let requirement = Ready.make_output_requirement
        ~schema:(`Assoc [ "type", `String "object" ])
        ~minimum_guarantee:Ready.Json_syntax in
    let ready = Ready.admit ~target:selected ~messages requirement
      |> require_ok "wire ready plan" in
    let serialized = Plan.request_body ready.plan in
    (* Bind the inspected bytes to the opaque plan produced by actual runtime
       initialization and bootstrap, without dispatching a provider request. *)
    check string "runtime bootstrap freezes these exact request bytes"
      (Digestif.SHA256.(digest_string serialized |> to_hex))
      (EO.receipt_request_body_sha256 runtime_receipt);
    check int "request inspection performs no provider dispatch" 0
      (EO.receipt_dispatch_count runtime_receipt);
    Printf.eprintf "runtime request: %s\n%!" serialized;
    let body = Yojson.Safe.from_string serialized in
    check string "serialized explicit reasoning effort"
      (Llm_provider.Reasoning_effort.to_string effort)
      Yojson.Safe.Util.(body |> member "reasoning_effort" |> to_string))
    [ Llm_provider.Reasoning_effort.Low; Llm_provider.Reasoning_effort.High ]

let test_declared_lane_budget_reaches_serialized_request () =
  with_runtime @@ fun load ->
  let target = load "low" in
  let projected = EO.projection_target target in
  let preflight =
    Plan.preflight
      ~config:projected.config
      ~messages
      ~body_timeout_s:projected.body_timeout_s
      ~anthropic_thinking_control:projected.anthropic_thinking_control
    |> require_ok "preflight"
  in
  let plan = Plan.finalize_unmeasured preflight |> require_ok "finalize" in
  let serialized = Plan.request_body plan in
  let body = Yojson.Safe.from_string serialized in
  (* The lane declares 4096 while the catalog ceiling is 384000. The request
     must carry the lane's budget, not the ceiling: the ceiling is what the
     model can emit, and sending it made OpenRouter reserve the whole ceiling
     and answer 402 on a 400-byte judgment (2026-09-21). *)
  check int "the declared lane budget is the request max_tokens" 4096
    Yojson.Safe.Util.(body |> member "max_tokens" |> to_int)
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  run "Exact runtime reasoning"
    [ "preflight", [
        test_case "missing effort has the precise typed rejection" `Quick
          test_missing_effort_has_typed_request_rejection;
        test_case "runtime effort reaches actual Exact preflight" `Quick
          test_runtime_effort_reaches_exact_preflight;
        test_case "effort changes frozen identity and preserves captured target" `Quick
          test_effort_changes_frozen_exact_identity;
        test_case "low and high survive the actual request serializer" `Quick
          test_explicit_effort_reaches_serialized_request;
        test_case "the declared lane budget is the serialized max_tokens" `Quick
          test_declared_lane_budget_reaches_serialized_request ] ]
