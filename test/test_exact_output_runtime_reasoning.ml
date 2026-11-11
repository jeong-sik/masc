open Alcotest
open Masc
module EO = Agent_core.Exact_output
module Resolver = Llm_provider.Exact_output_resolver
module Plan = Llm_provider.Exact_output_plan
module Registry = Runtime_exact_output_registry

let messages = [ Llm_provider.Types.user_msg "Return one JSON object." ]
let requirement = EO.make_output_requirement
    ~schema:(`Assoc [ "type", `String "object" ]) ~minimum_guarantee:EO.Json_syntax

let require_ok label = function Ok x -> x | Error _ -> fail label

(* Plan admission refuses an Exact target without a body deadline
   (Missing_deadline), so the fixture provider declares one. No request
   leaves the process, so the value only has to be positive and finite. *)
let exact_body_timeout_s = 180.0

let openrouter_binding ?(enable_thinking = true) ?reasoning_effort () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~provider_id:"openrouter"
    ~model_id:"z-ai/glm-5.3-flash"
    ~base_url:"https://openrouter.ai/api/v1"
    ~request_path:"/chat/completions"
    ~enable_thinking
    ?reasoning_effort
    ~connect_timeout_s:180.
    ()

let test_missing_effort_has_typed_request_rejection () =
  let target : Resolver.declared_target =
    { target_ref = "openrouter.probe"
    ; binding = openrouter_binding ()
    ; credential = Resolver.Credential_not_declared
    ; body_timeout_s = Some exact_body_timeout_s
    ; model_declaration = Resolver.No_model_declaration } in
  let snapshot = Resolver.load_resolver_snapshot
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
  match Plan.preflight ~config:projected.config
      ~declared_headers:projected.declared_headers ~messages
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
[runtime.exact_output_lanes.board_attention_exact]
slots = ["openrouter.probe"]
max_output_tokens = 4096
[providers.openrouter]
protocol = "openai-compatible-http"
endpoint = "https://openrouter.ai/api/v1"
connect-timeout-s = 180.0
exact-body-timeout-s = %.1f
[providers.openrouter.credentials]
type = "env"
key = "OPENROUTER_API_KEY"
[models.probe]
api-name = "z-ai/glm-5.3-flash"
tools-support = true
thinking-support = true
reasoning-effort = %S
[openrouter.probe]
|} exact_body_timeout_s effort

(* The guide's checkpoint binding (docs/guides/tinker-integration.md,
   "Hot-Swapping a Fine-Tuned Checkpoint"): a tinker:// model the catalog has
   no row for, under the tinker provider row, whose block states the five
   reads an exact slot needs. The Librarian lane declares the guide's budget,
   the board lane one above the stated output ceiling, and the HITL lane
   none. *)
let tinker_checkpoint_toml effort = Printf.sprintf {|[runtime]
default = "tinker.tinker-inkling-ckpt"
[runtime.exact_output_lanes.librarian_exact]
slots = ["tinker.tinker-inkling-ckpt"]
max_output_tokens = 32768
[runtime.exact_output_lanes.hitl_auto_judge]
slots = ["tinker.tinker-inkling-ckpt"]
[runtime.exact_output_lanes.board_attention_exact]
slots = ["tinker.tinker-inkling-ckpt"]
max_output_tokens = 40000
[providers.tinker]
protocol = "openai-compatible-http"
endpoint = "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1"
connect-timeout-s = 1200.0
exact-body-timeout-s = 1200.0
[providers.tinker.credentials]
type = "env"
key = "TINKER_API_KEY"
[providers.tinker.healthcheck]
path = "/models"
[models.tinker-inkling-ckpt]
api-name = "tinker://example:train:0/sampler_weights/x"
max-context = 65536
tools-support = true
thinking-support = true
streaming = true
reasoning-effort = %S
[models.tinker-inkling-ckpt.capabilities]
thinking-control-format = "reasoning-effort-default-on"
accepted-reasoning-efforts = ["minimal", "low", "medium", "high", "xhigh"]
reasoning-streaming-format = "delta:reasoning_content"
supports-tool-choice = true
supports-required-tool-choice = true
supports-parallel-tool-calls = true
supports-named-tool-choice = false
supports-response-format-json = false
supports-structured-output = false
supports-image-input = false
supports-multimodal-inputs = false
max-output-tokens = 32768
[tinker.tinker-inkling-ckpt]
max-concurrent = 4
|} effort

let with_runtime ?(toml = runtime_toml) ?(credential_env = "OPENROUTER_API_KEY") f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env credential_env (Some "synthetic-no-network") @@ fun () ->
  let root = Filename.temp_dir "exact-runtime-reasoning-" "" in
  let previous_runtime = Runtime.For_testing.snapshot () in
  let previous_startup = Runtime_startup_state.get () in
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  Fun.protect ~finally:(fun () ->
    Registry.unpublish () |> require_ok "unpublish fixture registry";
    Runtime.For_testing.restore previous_runtime;
    Runtime_startup_state.set previous_startup;
    (Llm_provider.Catalog_snapshot.publish previous_catalog);
    Fs_compat.remove_tree root) @@ fun () ->
  (Llm_provider.Catalog_snapshot.reset ());
  let load ?(lane_id = "librarian_exact") effort =
    let path = Filename.concat root "runtime.toml" in
    Fs_compat.save_file path (toml effort);
    Runtime.init_default ~config_path:path |> require_ok "runtime initialization";
    let runtime = match Runtime.get_runtimes () with
      | [ runtime ] -> runtime | _ -> fail "expected one runtime" in
    (match runtime.Runtime_instance.execution with
     | Runtime_execution.Agent_core sealed ->
       let config = Runtime_account_access.api_declaration sealed in
       check (option string) "ordinary runtime retains its declared effort" (Some effort)
         (Option.map Llm_provider.Reasoning_effort.to_string config.reasoning_effort)
     | _ -> fail "expected the API runtime");
    Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ();
    let registry = Registry.current () |> require_ok "published registry" in
    match Registry.resolve_lane registry ~lane_id with
    | Ok { selected_slots = [ slot ]; _ } -> slot.admitted_target
    | _ -> failf "expected one admitted %s slot" lane_id in
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
      ; body_timeout_s = Some exact_body_timeout_s
      ; model_declaration = Resolver.No_model_declaration } in
    let snapshot = Resolver.load_resolver_snapshot
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
      (Agent_core_sha256.(digest_string serialized |> to_hex))
      (EO.receipt_request_body_sha256 runtime_receipt);
    check int "request inspection performs no provider dispatch" 0
      (EO.receipt_dispatch_count runtime_receipt);
    Printf.eprintf "runtime request: %s\n%!" serialized;
    let body = Yojson.Safe.from_string serialized in
    check string "serialized explicit reasoning effort"
      (Llm_provider.Reasoning_effort.to_string effort)
      Yojson.Safe.Util.(body |> member "reasoning_effort" |> to_string))
    [ Llm_provider.Reasoning_effort.Low; Llm_provider.Reasoning_effort.High ]

let serialized_body target =
  let projected = EO.projection_target target in
  let preflight =
    Plan.preflight
      ~config:projected.config
      ~declared_headers:projected.declared_headers
      ~messages
      ~body_timeout_s:projected.body_timeout_s
      ~anthropic_thinking_control:projected.anthropic_thinking_control
    |> require_ok "preflight"
  in
  let plan = Plan.finalize_unmeasured preflight |> require_ok "finalize" in
  Yojson.Safe.from_string (Plan.request_body plan)

(* The catalog ceiling is 384000. The Librarian lane declares 4096 and its
   request carries that; the HITL lane declares nothing and its request
   carries no max_tokens, so the provider's default applies. The ceiling is
   what the model can emit and is never the request budget. *)
let test_declared_lane_budget_reaches_serialized_request () =
  with_runtime @@ fun load ->
  check int "the declared lane budget is the request max_tokens" 4096
    Yojson.Safe.Util.(serialized_body (load "low") |> member "max_tokens" |> to_int);
  check bool "a lane with no budget sends no max_tokens" true
    (Yojson.Safe.Util.(
       serialized_body (load ~lane_id:"hitl_auto_judge" "low") |> member "max_tokens")
     = `Null)
;;

(* The runtime's declared target, run through the wire resolver so the bytes
   of its request can be read. *)
let wire_declared_target (target : EO.declared_target) : Resolver.declared_target =
  { target_ref = target.target_ref
  ; binding = target.binding
  ; credential =
      (match target.credential with
       | EO.Credential_not_declared -> Resolver.Credential_not_declared
       | EO.Credential_resolved key -> Resolver.Credential_resolved key
       | EO.Credential_unresolved { environment_variable } ->
         Resolver.Credential_unresolved { environment_variable })
  ; body_timeout_s = target.body_timeout_s
  ; model_declaration =
      (match target.model_declaration with
       | EO.No_model_declaration -> Resolver.No_model_declaration
       | EO.Declared_model capabilities -> Resolver.Declared_model capabilities)
  }

(* The request bytes the runtime bootstrap froze for [admitted], the slot a
   lane resolved to. They are read from the wire plan of the declared target
   the runtime built, admitted the way the lane admits it ([lane_budget] is
   the lane's [max_output_tokens]), and the digest ties them to the runtime
   plan. The wire plan goes through ready admission, as the lane's request
   does: [serialized_body] preflights the projection config as it stands, and
   a binding that declares [max-concurrent] (the guide's does) is refused
   there as [Global_admission_not_allowed]. *)
let checkpoint_request_body ?lane_budget admitted =
  let module Ready = Llm_provider.Exact_output_ready_admission in
  let runtime_receipt = EO.start_attempt (ready admitted)
    |> require_ok "runtime attempt" |> EO.attempt_receipt in
  let declared =
    match Runtime.exact_output_targets (Runtime.get_runtimes ()) with
    | Ok [ declared ] -> wire_declared_target declared
    | Ok _ -> fail "expected the checkpoint binding as the one exact target"
    | Error refusal -> fail (Runtime_account_access.refusal_to_string refusal) in
  let snapshot = Resolver.load_resolver_snapshot
      ~catalog:(Resolver.Embedded_with_targets [ declared ]) ()
    |> require_ok "wire resolver snapshot" in
  let wire_admitted = Resolver.admit_target_ref snapshot declared.target_ref
    |> require_ok "wire admitted target" in
  let selected =
    (match lane_budget with
     | Some budget -> Resolver.admitted_target_with_max_tokens wire_admitted budget
     | None -> wire_admitted)
    |> Resolver.resolve_target
    |> require_ok "wire selected target"
  in
  let wire_requirement = Ready.make_output_requirement
      ~schema:(`Assoc [ "type", `String "object" ])
      ~minimum_guarantee:Ready.Json_syntax in
  let wire_plan = Ready.admit ~target:selected ~messages wire_requirement
    |> require_ok "wire ready plan" in
  let serialized = Plan.request_body wire_plan.plan in
  check string "runtime bootstrap freezes these exact request bytes"
    (Agent_core_sha256.(digest_string serialized |> to_hex))
    (EO.receipt_request_body_sha256 runtime_receipt);
  Printf.eprintf "checkpoint request: %s\n%!" serialized;
  Yojson.Safe.from_string serialized

(* The guide's checkpoint binding on its Librarian lane: the request carries
   the binding's effort and the lane's budget, within the slot's stated output
   ceiling, and no response_format, since the block states neither JSON mode
   nor native schema. The lane decides max_tokens; the stated ceiling only
   cuts it, as on the board lane, whose budget is above it. On the HITL lane,
   which declares no budget, the request carries no max_tokens. *)
let test_guide_checkpoint_request_carries_its_effort_and_lane_budget_and_no_envelope () =
  with_runtime ~toml:tinker_checkpoint_toml ~credential_env:"TINKER_API_KEY" @@ fun load ->
  List.iter (fun effort ->
    let effort_name = Llm_provider.Reasoning_effort.to_string effort in
    let admitted = load effort_name in
    let capabilities = (EO.projection_target admitted).capabilities in
    check bool "the slot has the stated JSON mode" false
      capabilities.supports_response_format_json;
    check bool "the slot has the stated native schema" false
      capabilities.supports_structured_output;
    check (option int) "the slot has the stated output ceiling" (Some 32768)
      capabilities.max_output_tokens;
    let body = checkpoint_request_body ~lane_budget:32768 admitted in
    check string "the request carries the binding's effort" effort_name
      Yojson.Safe.Util.(body |> member "reasoning_effort" |> to_string);
    let max_tokens = Yojson.Safe.Util.(body |> member "max_tokens" |> to_int) in
    check int "the request max_tokens is the lane budget" 32768 max_tokens;
    check bool "the lane budget stays within the slot's output ceiling" true
      (match capabilities.max_output_tokens with
       | Some ceiling -> max_tokens <= ceiling
       | None -> false);
    check bool "the request carries no response_format" true
      (Yojson.Safe.Util.member "response_format" body = `Null))
    [ Llm_provider.Reasoning_effort.Low; Llm_provider.Reasoning_effort.High ];
  check int "a lane budget above the stated output ceiling is cut to it" 32768
    Yojson.Safe.Util.(
      checkpoint_request_body ~lane_budget:40000
        (load ~lane_id:"board_attention_exact" "low")
      |> member "max_tokens" |> to_int);
  check bool "a lane with no budget sends no max_tokens" true
    (Yojson.Safe.Util.member "max_tokens"
       (checkpoint_request_body (load ~lane_id:"hitl_auto_judge" "low"))
     = `Null)
;;

(* One declared target, published straight into the registry with one lane,
   so a lane's [thinking] is checked against the slot's own capabilities. *)
let publish_thinking_lane ~binding ~thinking =
  let target : EO.declared_target =
    { target_ref = "openrouter.probe"
    ; binding
    ; credential = EO.Credential_not_declared
    ; body_timeout_s = Some exact_body_timeout_s
    ; model_declaration = EO.No_model_declaration } in
  let snapshot = EO.load_resolver_snapshot
      ~catalog:(EO.Embedded_with_targets [ target ]) ()
    |> require_ok "resolver snapshot" in
  Registry.publish
    ~lanes:
      [ { Runtime_schema.owner = Runtime_schema.Builtin Standalone_lane.Board_attention
        ; enabled = true
        ; slot_ids = [ target.target_ref ]
        ; cli_slot_ids = []
        ; max_output_tokens = None
        ; thinking } ]
    snapshot

let with_unpublished f =
  Fun.protect ~finally:(fun () ->
    match Registry.unpublish () with Ok () | Error _ -> ()) f

(* The slot declares thinking off with an effort its ladder accepts. The lane
   that declares [thinking = true] sends it on; the lane with no [thinking]
   keeps the slot's own off. *)
let test_declared_lane_thinking_reaches_request_config () =
  with_unpublished @@ fun () ->
  let binding () =
    openrouter_binding ~enable_thinking:false
      ~reasoning_effort:Llm_provider.Reasoning_effort.Low () in
  let enable_thinking thinking =
    let registry = publish_thinking_lane ~binding:(binding ()) ~thinking
      |> require_ok "published registry" in
    match Registry.resolve_lane registry ~lane_id:"board_attention_exact" with
    | Ok { selected_slots = [ slot ]; _ } ->
      (EO.projection_target slot.admitted_target).config.enable_thinking
    | _ -> fail "expected one admitted slot" in
  check (option bool) "a lane that declares thinking = true sends it" (Some true)
    (enable_thinking (Some true));
  check (option bool) "a lane with no thinking keeps the slot's own" (Some false)
    (enable_thinking None)

(* glm-5.3-flash on OpenRouter makes reasoning mandatory: its effort ladder
   has no [none]. A lane that asks it for thinking = false would publish and
   then refuse every request, so publication refuses it and names the slot. *)
let test_lane_thinking_the_slot_cannot_carry_is_refused () =
  with_unpublished @@ fun () ->
  match
    publish_thinking_lane
      ~binding:(openrouter_binding ~reasoning_effort:Llm_provider.Reasoning_effort.Low ())
      ~thinking:(Some false)
  with
  | Error (Registry.Lane_thinking_not_encodable { lane_id; slot_id; thinking; _ } as error) ->
    Printf.eprintf "refusal: %s\n%!" (Registry.publication_error_to_string error);
    check string "names the lane" "board_attention_exact" lane_id;
    check string "names the slot" "openrouter.probe" slot_id;
    check bool "names the setting" false thinking
  | Error error ->
    failf "a different publication error: %s" (Registry.publication_error_to_string error)
  | Ok _ -> fail "a lane whose slot cannot turn thinking off was published"

(* A Board Attention slot on ollama.com (deepseek-v4-pro) whose runtime row
   declares thinking-control-format "none" and thinking-support. That wire has
   no thinking control to turn reasoning off, so a lane that asks it for
   thinking = false is refused where the registry is published -- boot names
   the lane and the slot instead of publishing a lane that the slot would
   silently ignore. *)
let shipped_second_slot_toml = {|[runtime]
default = "ollama_cloud.deepseek-v4-pro"
[runtime.exact_output_lanes.board_attention_exact]
slots = ["ollama_cloud.deepseek-v4-pro"]
thinking = false
[runtime.exact_output_lanes.hitl_auto_judge]
slots = ["ollama_cloud.deepseek-v4-pro"]
[providers.ollama_cloud]
protocol = "openai-compatible-http"
endpoint = "https://ollama.com/v1"
connect-timeout-s = 600.0
exact-body-timeout-s = 1200.0
[providers.ollama_cloud.credentials]
type = "env"
key = "OLLAMA_CLOUD_API_KEY"
[models.deepseek-v4-pro]
reasoning-uncontrolled = true
api-name = "deepseek-v4-pro"
tools-support = true
thinking-support = true
streaming = true
[models.deepseek-v4-pro.capabilities]
max-output-tokens = 384000
thinking-control-format = "none"
[ollama_cloud.deepseek-v4-pro]
|}

let test_shipped_board_second_slot_refuses_thinking_off () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OLLAMA_CLOUD_API_KEY" (Some "synthetic-no-network") @@ fun () ->
  let root = Filename.temp_dir "exact-shipped-thinking-" "" in
  let previous_runtime = Runtime.For_testing.snapshot () in
  let previous_startup = Runtime_startup_state.get () in
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  Fun.protect ~finally:(fun () ->
    (match Registry.unpublish () with Ok () | Error _ -> ());
    Runtime.For_testing.restore previous_runtime;
    Runtime_startup_state.set previous_startup;
    (Llm_provider.Catalog_snapshot.publish previous_catalog);
    Fs_compat.remove_tree root) @@ fun () ->
  (Llm_provider.Catalog_snapshot.reset ());
  let path = Filename.concat root "runtime.toml" in
  Fs_compat.save_file path shipped_second_slot_toml;
  Runtime.init_default ~config_path:path |> require_ok "runtime initialization";
  match Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root () with
  | exception Env_config_core.Config_error detail ->
    Printf.eprintf "boot refusal: %s\n%!" detail;
    check bool "the refusal names the lane's thinking" true
      (Astring.String.is_infix ~affix:"cannot send thinking = false" detail)
  | () -> fail "the shipped second slot cannot turn thinking off, yet the lane published"

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
          test_declared_lane_budget_reaches_serialized_request;
        test_case "the guide's checkpoint binding sends its effort and lane budget, no envelope" `Quick
          test_guide_checkpoint_request_carries_its_effort_and_lane_budget_and_no_envelope;
        test_case "the declared lane thinking reaches the request config" `Quick
          test_declared_lane_thinking_reaches_request_config;
        test_case "a lane thinking the slot cannot carry is refused at publication" `Quick
          test_lane_thinking_the_slot_cannot_carry_is_refused;
        test_case "the shipped Board second slot refuses thinking = false at boot" `Quick
          test_shipped_board_second_slot_refuses_thinking_off ] ]
