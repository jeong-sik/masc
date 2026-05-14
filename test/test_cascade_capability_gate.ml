(** test_cascade_capability_gate — Provider ceiling validation.

    Verifies TLA+ KeeperCoreTriad.CapabilityGate (S3 invariant):
    requested_max_tokens never exceeds provider ceiling before dispatch. *)

open Alcotest

module CI = Masc_mcp.Cascade_inference
module CE = Masc_mcp.Cascade_error_classify
module CR = Masc_mcp.Cascade_runtime

let cascade_name = Masc_mcp.Keeper_cascade_profile.Runtime_name "keeper_unified"

let validate ?(provider_ceiling = Some 40960) max_tokens =
  CI.validate_max_tokens_within_ceiling
    ~cascade_name
    ~provider_ceiling
    max_tokens

let check_violation expected_reason expected_requested expected_ceiling = function
  | Error
      (CE.Max_tokens_ceiling_violation
         { cascade_name; requested_max_tokens; provider_ceiling; reason }) ->
    check
      string
      "cascade_name"
      "keeper_unified"
      (CE.cascade_name_to_string cascade_name);
    check int "requested_max_tokens" expected_requested requested_max_tokens;
    check int "provider_ceiling" expected_ceiling provider_ceiling;
    check string "reason" expected_reason reason
  | Error _ -> fail "expected max_tokens ceiling violation"
  | Ok value -> failf "expected validation error, got Ok %d" value

let check_ok label expected = function
  | Ok actual -> check int label expected actual
  | Error _ -> failf "expected Ok %d" expected

let test_reject_above_ceiling () =
  validate 65536
  |> check_violation "requested_exceeds_provider_ceiling" 65536 40960

let test_allow_below_ceiling () =
  let result = validate ~provider_ceiling:(Some 131072) 32768 in
  check_ok "32768 accepted (below ceiling)" 32768 result

let test_allow_equal_ceiling () =
  let result = validate ~provider_ceiling:(Some 32768) 32768 in
  check_ok "equal to ceiling accepted" 32768 result

let test_allow_no_ceiling () =
  let result = validate ~provider_ceiling:None 65536 in
  check_ok "None ceiling accepted" 65536 result

let test_reject_zero_ceiling () =
  validate ~provider_ceiling:(Some 0) 1024
  |> check_violation "provider_ceiling_not_positive" 1024 0

let test_reject_nonpositive_max_tokens () =
  validate 0 |> check_violation "max_tokens_not_positive" 0 40960

let test_sdk_error_round_trip_preserves_structured_violation () =
  match validate 65536 with
  | Ok _ -> fail "expected validation error"
  | Error internal_error ->
    let err = CE.sdk_error_of_masc_internal_error internal_error in
    (match CE.classify_masc_internal_error err with
     | Some
         (CE.Max_tokens_ceiling_violation
            { requested_max_tokens; provider_ceiling; reason; _ }) ->
       check int "requested round trip" 65536 requested_max_tokens;
       check int "ceiling round trip" 40960 provider_ceiling;
       check string "reason round trip" "requested_exceeds_provider_ceiling" reason
     | _ -> fail "expected structured violation round trip")

let write_file path body =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc body)

let with_temp_cascade_toml body f =
  let dir = Filename.temp_file "cascade-capability-gate-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let config_path = Filename.concat dir "cascade.toml" in
  write_file config_path body;
  let saved_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  let restore_env () =
    match saved_config_dir with
    | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
    | None -> Unix.putenv "MASC_CONFIG_DIR" ""
  in
  Unix.putenv "MASC_CONFIG_DIR" dir;
  Masc_mcp.Config_dir_resolver.reset ();
  Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ();
  Fun.protect
    ~finally:(fun () ->
      restore_env ();
      Masc_mcp.Config_dir_resolver.reset ();
      Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ();
      Sys.remove config_path;
      Unix.rmdir dir)
    f

let test_cascade_output_cap_not_context_window () =
  with_temp_cascade_toml
    {|
[providers.remote]
protocol = "openai-http"
endpoint = "https://example.test/v1"

[models.long]
api-name = "remote-long"
max-context = 200000
tools-support = true

[models.long.capabilities]
max-output-tokens = 8192

[remote.long]
max-concurrent = 1

[tier.primary]
members = ["remote.long"]

[routes.keeper_unified]
target = "tier.primary"
|}
    (fun () ->
      let ceiling = CR.max_output_tokens_ceiling_of_cascade_name cascade_name in
      check (option int) "output ceiling" (Some 8192) ceiling;
      CI.validate_max_tokens_within_ceiling ~cascade_name
        ~provider_ceiling:ceiling 65536
      |> check_violation "requested_exceeds_provider_ceiling" 65536 8192)

let test_resolve_max_tokens_caps_automatic_value_to_cascade_ceiling () =
  with_temp_cascade_toml
    {|
[providers.claude_code]
protocol = "anthropic-cli"
command = "claude"
is-non-interactive = true

[providers.kimi_cli]
protocol = "kimi-cli"
command = "kimi"
is-non-interactive = true

[models.claude-auto]
api-name = "auto"
max-context = 200000
tools-support = true

[models.claude-auto.capabilities]
max-output-tokens = 64000

[models.kimi-cli-coding]
api-name = "kimi-for-coding"
max-context = 128000
tools-support = true

[models.kimi-cli-coding.capabilities]
max-output-tokens = 16384

[claude_code.claude-auto]
max-concurrent = 1

[kimi_cli.kimi-cli-coding]
max-concurrent = 1

[claude_code.claude-auto.tool_candidate]
max-output = 64000
temperature = 0.2

[kimi_cli.kimi-cli-coding.tool_candidate]
max-output = 16384
temperature = 0.2

[tier.strict_tool_candidates]
members = ["claude_code.claude-auto.tool_candidate", "kimi_cli.kimi-cli-coding.tool_candidate"]
strategy = "failover"

[tier-group.strict_tool_candidates]
tiers = ["strict_tool_candidates"]
strategy = "failover"

[routes.keeper_unified]
target = "tier-group.strict_tool_candidates"
|}
    (fun () ->
      let ceiling = CR.max_output_tokens_ceiling_of_cascade_name cascade_name in
      check (option int) "mixed cascade output ceiling" (Some 16384) ceiling;
      let resolved =
        CI.resolve_max_tokens ~cascade_name ~fallback:(fun () -> 65536)
      in
      check int "automatic max_tokens capped to ceiling" 16384 resolved;
      CI.validate_max_tokens_within_ceiling ~cascade_name
        ~provider_ceiling:ceiling resolved
      |> check_ok "capped value accepted" 16384)

let () =
  run "cascade_capability_gate" [
    "max_tokens_ceiling_validation", [
      test_case "above ceiling -> rejected" `Quick test_reject_above_ceiling;
      test_case "below ceiling -> accepted" `Quick test_allow_below_ceiling;
      test_case "equal ceiling -> accepted" `Quick test_allow_equal_ceiling;
      test_case "no ceiling -> accepted" `Quick test_allow_no_ceiling;
      test_case "zero ceiling -> rejected" `Quick test_reject_zero_ceiling;
      test_case "nonpositive max_tokens -> rejected" `Quick test_reject_nonpositive_max_tokens;
      test_case
        "structured error round trip"
        `Quick
        test_sdk_error_round_trip_preserves_structured_violation;
      test_case
        "cascade output cap, not context window, gates max_tokens"
        `Quick
        test_cascade_output_cap_not_context_window;
      test_case
        "automatic max_tokens respects mixed failover ceiling"
        `Quick
        test_resolve_max_tokens_caps_automatic_value_to_cascade_ceiling;
    ];
  ]
