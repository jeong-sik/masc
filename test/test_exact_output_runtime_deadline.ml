open Alcotest
open Masc

module EO = Agent_core.Exact_output
module Registry = Runtime_exact_output_registry

let require_ok label = function Ok value -> value | Error _ -> fail label
let lane_id = "librarian_exact"
let messages = [ Agent_core.Types.user_msg "Return one JSON object." ]
let requirement =
  EO.make_output_requirement
    ~schema:(`Assoc [ "type", `String "object" ])
    ~minimum_guarantee:EO.Json_syntax

let runtime_toml ~connect ~body =
  let deadline key = function
    | None -> ""
    | Some value -> Printf.sprintf "%s = %.1f\n" key value
  in
  Printf.sprintf {|[runtime]
default = "openai-responses.probe"
%s
[providers.openai-responses]
protocol = "openai-compatible-http"
endpoint = "https://api.openai.com"
%s%s
[providers.openai-responses.credentials]
type = "env"
key = "OPENAI_API_KEY"
[models.probe]
api-name = "gpt-5.6-luna"
[openai-responses.probe]
|}
    (String.concat "\n"
       (List.map
          (fun lane -> Printf.sprintf "[runtime.exact_output_lanes.%s]\nslots = [\"openai-responses.probe\"]\nmax_output_tokens = 4096" lane)
          (List.sort_uniq String.compare
             (lane_id :: Server_runtime_bootstrap.mandatory_exact_output_lane_ids))))
    (deadline Runtime_schema.connect_timeout_s_key connect)
    (deadline Runtime_schema.exact_body_timeout_s_key body)

let ready target =
  (match EO.project_request_body ~target ~messages requirement with
   | Ok _ -> ()
   | Error error -> failf "Exact projection: %s" (EO.admission_error_reason error));
  let selected = EO.resolve_target target |> require_ok "resolve frozen credential" in
  match EO.admit ~target:selected ~messages requirement with
  | Ok plan -> plan
  | Error error -> failf "Exact admission: %s" (EO.admission_error_reason error)

let expected_plan ~connect ~body =
  let target : EO.declared_target =
    { target_ref = "openai-responses.probe"
    ; binding =
        Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.OpenAI_compat
          ~provider_id:"openai-responses"
          ~model_id:"gpt-5.6-luna"
          ~base_url:"https://api.openai.com"
          ~request_path:"/v1/responses"
          ?connect_timeout_s:connect
          ()
    ; credential =
        EO.Credential_resolved (Llm_provider.Secret.of_string "synthetic-no-network")
    ; body_timeout_s = body }
  in
  let snapshot =
    EO.load_resolver_snapshot
      ~io:{ getenv = (fun name -> Ok (Sys.getenv_opt name)) }
      ~target_binding_policy:EO.Exclude_unbound_targets
      ~catalog:(EO.Embedded_with_targets [ target ]) ()
    |> require_ok "expected declared target snapshot"
  in
  EO.admit_target_ref snapshot target.target_ref
  |> require_ok "expected admitted target"
  (* The runtime bootstrap runs this target through a lane that declares
     [max_output_tokens = 4096]; the expected plan must carry the same budget
     or the fingerprints differ for a reason this test is not about. *)
  |> fun admitted -> EO.admitted_target_with_max_tokens admitted 4096
  |> ready

let with_runtime f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OPENAI_API_KEY" (Some "synthetic-no-network") @@ fun () ->
  let root = Filename.temp_dir "exact-runtime-deadline-" "" in
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some root) @@ fun () ->
  Config_dir_resolver.reset ();
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
    Config_dir_resolver.reset ();
    Fs_compat.remove_tree root) @@ fun () ->
  Llm_provider.Model_catalog.clear_global ();
  let load ~connect ~body =
    let path = Filename.concat root "runtime.toml" in
    Fs_compat.save_file path (runtime_toml ~connect ~body);
    (match Runtime.init_default ~config_path:path with
     | Ok () -> ()
     | Error detail -> failf "runtime initialization: %s" detail);
    let runtime = match Runtime.get_runtimes () with
      | [ runtime ] -> runtime | _ -> fail "expected one runtime" in
    check (option (float 0.0)) "declared Exact body deadline" body
      runtime.provider.exact_body_timeout_s;
    (match runtime.Runtime.execution with
     | Runtime_execution.Agent_core config ->
       check (option (float 0.0)) "ordinary connection deadline is unchanged" connect
         config.connect_timeout_s
     | _ -> fail "expected the API runtime");
    let inventory = Server_dashboard_http_runtime_info.runtime_inventory_json () in
    let open Yojson.Safe.Util in
    let entry = match inventory |> member "providers" |> to_list with
      | [ entry ] -> entry | _ -> fail "expected one dashboard runtime" in
    let declared = entry |> member "declared_spec" |> member "provider" in
    check bool "dashboard exposes the declared Exact deadline" true
      ((declared |> member "exact_body_timeout_s") = Json_util.float_opt_to_json body);
    Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ();
    let registry = Registry.current () |> require_ok "published registry" in
    match Registry.resolve_lane registry ~lane_id with
    | Ok { selected_slots = [ slot ]; _ } -> slot.admitted_target
    | _ -> fail "expected one admitted Librarian slot"
  in
  f load

let test_body_only_declaration_reaches_exact () =
  with_runtime @@ fun load ->
  let connect, body = None, Some 91.5 in
  let actual = load ~connect ~body |> ready in
  check (option (float 0.0)) "body-only plan has no connection deadline" None
    (EO.connect_timeout_s actual);
  check (option (float 0.0)) "body-only plan preserves its total deadline" body
    (EO.body_timeout_s actual);
  check string "bootstrap and direct declared body produce the same plan"
    (EO.plan_fingerprint (expected_plan ~connect ~body)) (EO.plan_fingerprint actual)

let test_deadlines_are_independent_and_frozen () =
  with_runtime @@ fun load ->
  let connect = Some 17.5 in
  let capture body =
    let target = load ~connect ~body in
    let plan = ready target in
    check string "the full frozen plan preserves both declared deadline values"
      (EO.plan_fingerprint (expected_plan ~connect ~body)) (EO.plan_fingerprint plan);
    target, plan
  in
  let first_target, first = capture (Some 91.5) in
  let _, second = capture (Some 55.5) in
  check (option (float 0.0)) "explicit body deadline leaves connection independent" connect
    (EO.connect_timeout_s first);
  check (option (float 0.0)) "explicit body deadline reaches the frozen plan" (Some 91.5)
    (EO.body_timeout_s first);
  check bool "changing only body changes the frozen plan" true
    (EO.plan_fingerprint first <> EO.plan_fingerprint second);
  check string "republishing leaves the captured first target unchanged"
    (EO.plan_fingerprint first) (EO.plan_fingerprint (ready first_target))

(* A connect deadline ends at the response headers, so a provider that
   declares only [connect-timeout-s] would read the Exact body with no
   deadline (#36979). The runtime still loads it; plan admission refuses it. *)
let test_connect_only_declaration_is_refused () =
  with_runtime @@ fun load ->
  let target = load ~connect:(Some 17.5) ~body:None in
  let selected = EO.resolve_target target |> require_ok "resolve frozen credential" in
  match EO.admit ~target:selected ~messages requirement with
  | Ok _ -> fail "connect-only Exact target was admitted"
  | Error error ->
    check string "connect-only Exact target is refused for its missing body deadline"
      "wire_admission_rejected:missing_deadline" (EO.admission_error_reason error)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  run "Exact runtime deadline"
    [ "declaration", [
        test_case "body-only declaration reaches actual Exact projection" `Quick
          test_body_only_declaration_reaches_exact;
        test_case "connection and body deadlines remain independent and frozen" `Quick
          test_deadlines_are_independent_and_frozen;
        test_case "connect-only declaration is refused at admission" `Quick
          test_connect_only_declaration_is_refused ] ]
