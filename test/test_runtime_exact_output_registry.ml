(* Exact-output registry: credential admission is deferred to execution at
   publish time, and runtime.toml saves re-validate + republish lane
   declarations against the live resolver snapshot. *)

open Alcotest
open Masc

module EO = Agent_sdk.Exact_output
module Registry = Runtime_exact_output_registry

let fixture_provider_id = "masc-exact-registry-provider"
let fixture_model_id = "masc-exact-registry-model"
let fixture_target_id = "masc-exact-registry-provider.masc-exact-registry-model"

let fixture_catalog_toml ~api_key_env =
  Printf.sprintf
    "[[providers]]\n\
     id = %S\n\
     kind = \"openai_compat\"\n\
     base_url = \"http://127.0.0.1:9\"\n\
     request_path = \"/v1/chat/completions\"\n\
     api_key_env = %S\n\
     \n\
     [[models]]\n\
     id_prefix = %S\n\
     provider_name = %S\n\
     max_context_tokens = 8192\n\
     max_output_tokens = 1024\n\
     supports_response_format_json = true\n\
     supports_structured_output = true\n\
     \n\
     [[targets]]\n\
     id = %S\n\
     provider_ref = %S\n\
     model_id = %S\n"
    fixture_provider_id
    api_key_env
    fixture_model_id
    fixture_provider_id
    fixture_target_id
    fixture_provider_id
    fixture_model_id
;;

let load_snapshot ~api_key_env =
  let overlay : EO.catalog_overlay =
    { source = "test fixture"; contents = fixture_catalog_toml ~api_key_env }
  in
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  match EO.load_resolver_snapshot ~io ~overlay () with
  | Ok snapshot -> snapshot
  | Error error ->
    failf
      "exact-output resolver fixture did not load: %s"
      (match error with
       | EO.Catalog_parse_failed { detail; _ } -> detail
       | _ -> "snapshot error")
;;

let lane id slot_ids : Runtime_schema.exact_output_lane_decl = { id; slot_ids }

let contains_substring haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop index =
    index + needle_length <= haystack_length
    && (String.sub haystack index needle_length = needle || loop (index + 1))
  in
  needle_length = 0 || loop 0
;;

let test_publish_defers_missing_credential_to_execution () =
  let snapshot = load_snapshot ~api_key_env:"MASC_TEST_EXACT_OUTPUT_UNSET_KEY" in
  let lanes = [ lane "compaction_exact" [ fixture_target_id ] ] in
  match Registry.publish ~lanes snapshot with
  | Error error ->
    failf
      "publish must not abort on a missing target credential: %s"
      (Registry.error_to_string error)
  | Ok registry ->
    (match Registry.lane_slots registry ~lane_id:"compaction_exact" with
     | Error error ->
       failf "lane lookup failed: %s" (Registry.error_to_string error)
     | Ok slot_ids ->
       check (list string) "lane keeps its slots" [ fixture_target_id ] slot_ids);
    (match Registry.resolve_slots registry [ fixture_target_id ] with
     | [ Ok _ ] -> fail "execution-time resolution must re-admit the credential"
     | [ Error error ] ->
       check bool
         "execution failure names the missing credential"
         true
         (contains_substring
            (Registry.error_to_string error)
            "MASC_TEST_EXACT_OUTPUT_UNSET_KEY")
     | outcomes ->
       failf "expected exactly one slot outcome, got %d" (List.length outcomes))
;;

let test_publish_rejects_unknown_target () =
  let snapshot = load_snapshot ~api_key_env:"" in
  let lanes = [ lane "compaction_exact" [ "masc-exact-registry-provider.unknown" ] ] in
  match Registry.publish ~lanes snapshot with
  | Ok _ -> fail "unknown lane targets must stay fatal at publish"
  | Error error ->
    check bool
      "error names the unknown target"
      true
      (contains_substring (Registry.error_to_string error) "unknown target")
;;

let test_republish_revalidates_against_current_snapshot () =
  let snapshot = load_snapshot ~api_key_env:"" in
  let lanes = [ lane "compaction_exact" [ fixture_target_id ] ] in
  (match Registry.publish ~lanes snapshot with
   | Error error ->
     failf "fixture publish failed: %s" (Registry.error_to_string error)
   | Ok first ->
     (match Registry.republish ~lanes:[ lane "compaction_exact" [ fixture_target_id ] ] with
      | Error error ->
        failf "valid republish failed: %s" (Registry.error_to_string error)
      | Ok second ->
        check bool
          "generation advances"
          true
          (Int64.equal
             (Registry.generation second)
             (Int64.succ (Registry.generation first))));
     match Registry.republish ~lanes:[ lane "compaction_exact" [ "no.such-target" ] ] with
     | Ok _ -> fail "republish must reject unknown lane targets"
     | Error error ->
       check bool
         "republish error names the target"
         true
         (contains_substring (Registry.error_to_string error) "no.such-target");
       (match Registry.current () with
        | Error _ -> fail "registry must remain published after a rejected republish"
        | Ok current ->
          check bool
            "rejected republish does not advance the published generation"
            true
            (Int64.equal
               (Registry.generation current)
               (Int64.succ (Registry.generation first)))))
;;

let runtime_config_text ~extra =
  "[providers.local]\n\
   display-name = \"Local\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11434\"\n\
   \n\
   [models.chat]\n\
   api-name = \"chat\"\n\
   max-context = 1024\n\
   \n\
   [local.chat]\n\
   \n\
   [runtime]\n\
   default = \"local.chat\"\n"
  ^ extra
;;

let test_save_config_text_republishes_exact_output_lanes () =
  let snapshot = load_snapshot ~api_key_env:"" in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       match
         Registry.publish
           ~lanes:[ lane "compaction_exact" [ fixture_target_id ] ]
           snapshot
       with
       | Error error ->
         failf "fixture publish failed: %s" (Registry.error_to_string error)
       | Ok published ->
         let valid =
           runtime_config_text
             ~extra:
               (Printf.sprintf
                  "[runtime.exact_output_lanes.compaction_exact]\nslots = [ %S ]\n"
                  fixture_target_id)
         in
         let path = Filename.temp_file "runtime-exact-output" ".toml" in
         Fun.protect
           ~finally:(fun () ->
             try Sys.remove path with
             | Sys_error _ -> ())
           (fun () ->
             (match Runtime.save_config_text ~runtime_config_path:path valid with
              | Error msg -> failf "valid exact-output lane save failed: %s" msg
              | Ok () ->
                (match Registry.current () with
                 | Error _ -> fail "registry must stay published after a save"
                 | Ok current ->
                   check bool
                     "save republished a new generation"
                     true
                     (Int64.compare
                        (Registry.generation current)
                        (Registry.generation published)
                      > 0);
                   (match Registry.lane_slots current ~lane_id:"compaction_exact" with
                    | Error error ->
                      failf
                        "saved lane missing from registry: %s"
                        (Registry.error_to_string error)
                    | Ok slot_ids ->
                      check
                        (list string)
                        "registry serves the saved lane"
                        [ fixture_target_id ]
                        slot_ids)));
             let invalid =
               runtime_config_text
                 ~extra:
                   "[runtime.exact_output_lanes.compaction_exact]\n\
                    slots = [ \"no.such-target\" ]\n"
             in
             match Runtime.save_config_text ~runtime_config_path:path invalid with
             | Ok () -> fail "invalid exact-output lane must reject the save"
             | Error msg ->
               check bool
                 "save error surfaces the lane validation failure"
                 true
                 (contains_substring msg "no.such-target");
               let on_disk = In_channel.with_open_bin path In_channel.input_all in
               check bool
                 "rejected save never reaches disk"
                 true
                 (contains_substring on_disk fixture_target_id
                  && not (contains_substring on_disk "no.such-target"))))
;;

let () =
  Alcotest.run
    "Runtime_exact_output_registry"
    [ ( "registry"
      , [ test_case "publish defers missing credential" `Quick
            test_publish_defers_missing_credential_to_execution
        ; test_case "publish rejects unknown target" `Quick
            test_publish_rejects_unknown_target
        ; test_case "republish revalidates" `Quick
            test_republish_revalidates_against_current_snapshot
        ; test_case "config save republishes lanes" `Quick
            test_save_config_text_republishes_exact_output_lanes
        ] )
    ]
;;
