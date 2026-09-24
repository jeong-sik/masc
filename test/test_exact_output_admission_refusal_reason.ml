(* A slot masc refuses by itself has to say what it refused. The Librarian
   logs `wire_admission_rejected:<reason>` for an excluded slot, and while the
   reason was the bare kind name an operator could read the same line for
   three days without learning which control the binding could not send
   (#37674). This fixture declares a binding whose thinking request its wire
   cannot encode, and reads the refusal back. *)
open Alcotest
open Masc
module EO = Agent_core.Exact_output
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

(* thinking-support with no declared effort: this wire carries the thinking
   state in the effort field, so the request cannot be built and the provider
   config refuses it before dispatch (#37326 pins the same shape). *)
(* Plan admission refuses an Exact target without a body deadline
   (Missing_deadline), so the fixture provider declares one. No request
   leaves the process, so the value only has to be positive and finite. *)
let exact_body_timeout_s = 180.0

let runtime_toml =
  Printf.sprintf
    {|[runtime]
default = "openrouter.probe"
%s
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
[openrouter.probe]
|}
    (String.concat
       "\n"
       (List.map
          (fun lane ->
             Printf.sprintf
               "[runtime.exact_output_lanes.%s]\nslots = [\"openrouter.probe\"]\nmax_output_tokens = 4096"
               lane)
          (List.sort_uniq
             String.compare
             (lane_id :: Server_runtime_bootstrap.mandatory_exact_output_lane_ids))))
    exact_body_timeout_s
;;

let with_admitted_slot f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OPENROUTER_API_KEY" (Some "synthetic-no-network")
  @@ fun () ->
  let root = Filename.temp_dir "exact-refusal-reason-" "" in
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
       let path = Filename.concat root "runtime.toml" in
       Fs_compat.save_file path runtime_toml;
       Runtime.init_default ~config_path:path |> require_ok "runtime initialization";
       Server_runtime_bootstrap.For_testing.configure_exact_output_registry
         ~config_root:root
         ();
       let registry = Registry.current () |> require_ok "published registry" in
       match Registry.resolve_lane registry ~lane_id with
       | Ok { selected_slots = [ slot ]; _ } -> f slot.admitted_target
       | Ok _ | Error _ -> fail "expected one admitted slot")
;;

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec scan index =
    if index + n > h then false else String.sub haystack index n = needle || scan (index + 1)
  in
  n = 0 || scan 0
;;

let test_refusal_names_what_the_wire_could_not_send () =
  with_admitted_slot
  @@ fun target ->
  match EO.project_request_body ~target ~messages requirement with
  | Ok (_ : EO.request_body_projection) ->
    fail "this binding's thinking request has no wire encoding, so it cannot project"
  | Error error ->
    let reason = EO.admission_error_reason error in
    Printf.eprintf "refusal: %s\n%!" reason;
    check
      bool
      "the refusal still names its kind"
      true
      (contains ~needle:"target_request_rejected" reason);
    check
      bool
      "and carries what the provider config refused"
      true
      (contains ~needle:"enable_thinking" reason)
;;

let () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs
  @@ fun () ->
  run
    "Exact admission refusal reason"
    [ ( "reason"
      , [ test_case
            "a self-refused slot says what it refused"
            `Quick
            test_refusal_names_what_the_wire_could_not_send
        ] )
    ]
;;
