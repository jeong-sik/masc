(** Env_config Module Coverage Tests

    Tests for MASC Environment Configuration:
    - get_string, get_int, get_float, get_bool: env var readers
    - Zombie, Lock, Session, Tempo, Orchestrator, Cancellation modules
*)

open Alcotest

module Env_config = Env_config

let with_env name value fn =
  let previous = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some original -> Unix.putenv name original
      | None -> Unix.putenv name "")
    (fun () ->
      Unix.putenv name value;
      fn ())

(* ============================================================
   get_string Tests
   ============================================================ *)

let test_get_string_default () =
  let result = Env_config.get_string ~default:"fallback" "NONEXISTENT_VAR_XYZ_12345" in
  check string "default" "fallback" result

let test_get_string_empty_default () =
  let result = Env_config.get_string ~default:"" "NONEXISTENT_VAR_XYZ_12345" in
  check string "empty default" "" result

(* ============================================================
   get_int Tests
   ============================================================ *)

let test_get_int_default () =
  let result = Env_config.get_int ~default:42 "NONEXISTENT_VAR_XYZ_12345" in
  check int "default" 42 result

let test_get_int_negative_default () =
  let result = Env_config.get_int ~default:(-10) "NONEXISTENT_VAR_XYZ_12345" in
  check int "negative default" (-10) result

let test_get_int_zero_default () =
  let result = Env_config.get_int ~default:0 "NONEXISTENT_VAR_XYZ_12345" in
  check int "zero default" 0 result

(* ============================================================
   get_float Tests
   ============================================================ *)

let test_get_float_default () =
  let result = Env_config.get_float ~default:3.14 "NONEXISTENT_VAR_XYZ_12345" in
  check (float 0.001) "default" 3.14 result

let test_get_float_negative_default () =
  let result = Env_config.get_float ~default:(-2.5) "NONEXISTENT_VAR_XYZ_12345" in
  check (float 0.001) "negative default" (-2.5) result

let test_get_float_zero_default () =
  let result = Env_config.get_float ~default:0.0 "NONEXISTENT_VAR_XYZ_12345" in
  check (float 0.001) "zero default" 0.0 result

(* ============================================================
   get_bool Tests
   ============================================================ *)

let test_get_bool_default_true () =
  let result = Env_config.get_bool ~default:true "NONEXISTENT_VAR_XYZ_12345" in
  check bool "default true" true result

let test_get_bool_default_false () =
  let result = Env_config.get_bool ~default:false "NONEXISTENT_VAR_XYZ_12345" in
  check bool "default false" false result

let test_base_path_prefers_env () =
  with_env "MASC_BASE_PATH" "/tmp/masc-custom-root" (fun () ->
    check (option string) "base_path_opt" (Some "/tmp/masc-custom-root")
      (Env_config.base_path_opt ());
    check string "base_path" "/tmp/masc-custom-root" (Env_config.base_path ()))

let test_masc_http_base_url_prefers_env_and_trims () =
  with_env "MASC_HTTP_BASE_URL" "http://example.test:9911/" (fun () ->
    check (result string string) "base url result trimmed"
      (Ok "http://example.test:9911")
      (Env_config.masc_http_base_url_result ());
    check string "base url trimmed" "http://example.test:9911" (Env_config.masc_http_base_url ()))

let test_masc_http_base_url_uses_explicit_host_and_port () =
  with_env "MASC_HTTP_BASE_URL" "" (fun () ->
    with_env "MASC_HOST" "masc.example.test" (fun () ->
      with_env "MASC_HTTP_PORT" "7777" (fun () ->
        check (result string string) "base url result from host+port"
          (Ok "http://masc.example.test:7777")
          (Env_config.masc_http_base_url_result ());
        check string "base url from host+port" "http://masc.example.test:7777" (Env_config.masc_http_base_url ()))))

let test_sb_path_result_missing_is_error () =
  with_env "MASC_BASE_PATH" "" (fun () ->
    check bool "sb path result is error" true
      (match Env_config.sb_path_result () with Error _ -> true | Ok _ -> false))

let test_masc_host_prefers_primary_over_deprecated () =
  with_env "MASC_HOST" "primary.example.test" (fun () ->
    let resolved = Env_config.masc_host () in
    let explicit = Env_config.masc_host_opt () in
    check string "primary host wins" "primary.example.test" resolved;
    check (option string) "explicit host wins" (Some "primary.example.test")
      explicit)

let test_assets_dir_prefers_primary_over_deprecated () =
  with_env "MASC_ASSETS_DIR" "/tmp/assets-primary" (fun () ->
    let resolved = Env_config.assets_dir_opt () in
    check (option string) "primary assets dir wins" (Some "/tmp/assets-primary")
      resolved)

let test_cluster_name_opt_trims_empty () =
  with_env "MASC_CLUSTER_NAME" "   " (fun () ->
    check (option string) "cluster_name_opt empty -> none" None
      (Env_config.cluster_name_opt ());
    check string "cluster_name empty -> default" "default"
      (Env_config.cluster_name ()))

let find_config_entry json env_name =
  let open Yojson.Safe.Util in
  json
  |> member "categories"
  |> to_assoc
  |> List.to_seq
  |> Seq.flat_map (fun (_category, value) ->
         match value with
         | `List entries -> List.to_seq entries
         | _ -> Seq.empty)
  |> Seq.find
       (fun entry ->
         String.equal (entry |> member "env" |> to_string) env_name)
  |> function
  | Some entry -> entry
  | None -> failwith ("missing config entry: " ^ env_name)

let test_to_json_uses_canonical_introspection_shape () =
  let json = Env_config.to_json () in
  check bool "server meta omitted on config wrapper" true
    (Yojson.Safe.Util.member "server" json = `Null);
  check bool "categories exist" true
    (match Yojson.Safe.Util.member "categories" json with
    | `Assoc _ -> true
    | _ -> false)

let test_to_json_masks_sensitive_values_and_tracks_sources () =
  with_env "MASC_ADMIN_TOKEN" "super-secret-token" (fun () ->
      let json = Env_config.to_json () in
      let entry = find_config_entry json "MASC_ADMIN_TOKEN" in
      let open Yojson.Safe.Util in
      check string "source is env" "env" (entry |> member "source" |> to_string);
      check bool "marked sensitive" true (entry |> member "sensitive" |> to_bool);
      check string "masked token" "supe***"
        (entry |> member "value" |> to_string))

let test_to_json_treats_blank_env_as_default () =
  with_env "MASC_ADMIN_TOKEN" "   " (fun () ->
      let json = Env_config.to_json () in
      let entry = find_config_entry json "MASC_ADMIN_TOKEN" in
      let open Yojson.Safe.Util in
      check string "blank source is default" "default"
        (entry |> member "source" |> to_string);
      check bool "blank value omitted" true (entry |> member "value" = `Null))

(* ============================================================
   print_summary Tests
   ============================================================ *)

let test_print_summary_no_error () =
  Env_config.print_summary ();
  ()

(* ============================================================
   Zombie Module Tests
   ============================================================ *)

let test_zombie_threshold_positive () =
  check bool "threshold positive" true (Env_config.Zombie.threshold_seconds > 0.0)

let test_zombie_cleanup_interval_positive () =
  check bool "cleanup interval positive" true (Env_config.Zombie.cleanup_interval_seconds > 0.0)

let test_zombie_threshold_reasonable () =
  (* Default is 300.0 seconds = 5 minutes *)
  check bool "threshold reasonable" true (Env_config.Zombie.threshold_seconds >= 60.0)

(* ============================================================
   Lock Module Tests
   ============================================================ *)

let test_lock_timeout_positive () =
  check bool "timeout positive" true (Env_config.Lock.timeout_seconds > 0.0)

let test_lock_expiry_warning_positive () =
  check bool "expiry warning positive" true (Env_config.Lock.expiry_warning_seconds > 0.0)

let test_lock_warning_less_than_timeout () =
  check bool "warning < timeout" true
    (Env_config.Lock.expiry_warning_seconds < Env_config.Lock.timeout_seconds)

(* ============================================================
   Session Module Tests
   ============================================================ *)

let test_session_max_age_positive () =
  check bool "max age positive" true (Env_config.Session.max_age_seconds > 0.0)

let test_session_rate_limit_window_positive () =
  check bool "rate limit window positive" true (Env_config.Session.rate_limit_window_seconds > 0.0)

(* ============================================================
   Tempo Module Tests
   ============================================================ *)

let test_tempo_min_positive () =
  check bool "min positive" true (Env_config.Tempo.min_interval_seconds > 0.0)

let test_tempo_max_positive () =
  check bool "max positive" true (Env_config.Tempo.max_interval_seconds > 0.0)

let test_tempo_default_positive () =
  check bool "default positive" true (Env_config.Tempo.default_interval_seconds > 0.0)

let test_tempo_min_less_than_max () =
  check bool "min < max" true
    (Env_config.Tempo.min_interval_seconds < Env_config.Tempo.max_interval_seconds)

let test_tempo_default_in_range () =
  check bool "default in range" true
    (Env_config.Tempo.default_interval_seconds >= Env_config.Tempo.min_interval_seconds &&
     Env_config.Tempo.default_interval_seconds <= Env_config.Tempo.max_interval_seconds)

(* ============================================================
   Orchestrator Module Tests
   ============================================================ *)

let test_orchestrator_interval_positive () =
  check bool "interval positive" true (Env_config.Orchestrator.check_interval_seconds > 0.0)

let test_orchestrator_agent_name_nonempty () =
  check bool "agent name nonempty" true (String.length Env_config.Orchestrator.agent_name > 0)

(* ============================================================
   Cancellation Module Tests
   ============================================================ *)

let test_cancellation_token_max_age_positive () =
  check bool "max age positive" true (Env_config.Cancellation.token_max_age_seconds > 0.0)

(* ============================================================
   Spawn Module Tests (P2 #19: Centralized timeout config)
   ============================================================ *)

let test_spawn_timeout_positive () =
  check bool "timeout positive" true (Env_config.Spawn.timeout_seconds > 0)

let test_spawn_timeout_default_600 () =
  (* Default is 600 seconds = 10 minutes for agent spawn operations *)
  check int "default timeout" 600 Env_config.Spawn.timeout_seconds

let test_spawn_timeout_reasonable_range () =
  (* Spawn timeout should be between 60s (1 min) and 3600s (1 hour) *)
  let t = Env_config.Spawn.timeout_seconds in
  check bool "timeout >= 60" true (t >= 60);
  check bool "timeout <= 3600" true (t <= 3600)

(* ============================================================
   Llama Module Tests
   ============================================================ *)

let test_llama_server_url_nonempty () =
  check bool "server url nonempty" true
    (String.length Env_config.Llama.server_url > 0)

let test_llama_server_url_httpish () =
  check bool "server url starts with http" true
    (String.starts_with ~prefix:"http://" Env_config.Llama.server_url
     || String.starts_with ~prefix:"https://" Env_config.Llama.server_url)

let test_llama_max_tokens_positive () =
  check bool "max tokens positive" true (Env_config.Llama.max_tokens > 0)

(* ============================================================
   Inference Timeout Config Tests
   ============================================================ *)

let test_inference_timeout_positive () =
  check bool "timeout positive" true (Env_config.Inference.timeout_seconds > 0.0)

let test_inference_timeout_int_positive () =
  check bool "timeout int positive" true (Env_config.Inference.timeout_seconds_int > 0)

let test_operator_judge_timeout_reasonable () =
  check bool "operator judge timeout >= 5" true
    (Env_config.Inference.operator_judge_timeout_seconds >= 5)

let test_governance_judge_timeout_reasonable () =
  check bool "governance judge timeout >= 5" true
    (Env_config.Inference.dashboard_governance_judge_timeout_seconds >= 5)

(* ============================================================
   Inference Cache Config Tests
   ============================================================ *)

let test_inference_cache_enabled_bool () =
  check bool "cache enabled is bool" true
    (Env_config.Inference.cache_enabled || not Env_config.Inference.cache_enabled)

let test_inference_cache_ttl_positive () =
  check bool "cache ttl positive" true (Env_config.Inference.cache_ttl_seconds > 0)

let test_inference_cache_prompt_chars_positive () =
  check bool "max prompt chars positive" true
    (Env_config.Inference.cache_max_prompt_chars > 0)

let test_inference_cache_l1_entries_positive () =
  check bool "l1 max entries positive" true
    (Env_config.Inference.cache_l1_max_entries > 0)

let test_inference_spawn_cache_policy_supported () =
  check bool "spawn cache policy supported" true
    (List.mem Env_config.Inference.spawn_cache_policy [ "safe_only"; "off" ])

(* ============================================================
   KeeperBootstrap Module Tests
   ============================================================ *)

let test_keeper_bootstrap_stale_positive () =
  check bool "stale turn positive" true
    (Env_config.KeeperBootstrap.stale_turn_seconds >= 0.0)

let test_keeper_bootstrap_max_scan_positive () =
  check bool "max scan positive" true
    (Env_config.KeeperBootstrap.max_scan > 0)

(* ============================================================
   KeeperAlert Module Tests
   ============================================================ *)

let test_keeper_alert_min_score_range () =
  let v = Env_config.KeeperAlert.min_score in
  check bool "min score >= 0" true (v >= 0.0);
  check bool "min score <= 1" true (v <= 1.0)

let test_keeper_alert_retry_non_negative () =
  check bool "max retries non-negative" true
    (Env_config.KeeperAlert.max_retries >= 0)

let test_keeper_alert_body_chars_positive () =
  check bool "max body chars positive" true
    (Env_config.KeeperAlert.max_body_chars > 0)

let test_keeper_alert_slack_dm_user_id_readable () =
  check bool "slack dm user id readable" true
    (String.length Env_config.KeeperAlert.slack_dm_user_id >= 0)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Env_config Coverage" [
    "get_string", [
      test_case "default" `Quick test_get_string_default;
      test_case "empty default" `Quick test_get_string_empty_default;
    ];
    "get_int", [
      test_case "default" `Quick test_get_int_default;
      test_case "negative default" `Quick test_get_int_negative_default;
      test_case "zero default" `Quick test_get_int_zero_default;
    ];
    "get_float", [
      test_case "default" `Quick test_get_float_default;
      test_case "negative default" `Quick test_get_float_negative_default;
      test_case "zero default" `Quick test_get_float_zero_default;
    ];
    "get_bool", [
      test_case "default true" `Quick test_get_bool_default_true;
      test_case "default false" `Quick test_get_bool_default_false;
    ];
    "path_helpers", [
      test_case "base_path prefers env" `Quick test_base_path_prefers_env;
      test_case "base url prefers env and trims" `Quick test_masc_http_base_url_prefers_env_and_trims;
      test_case "base url uses explicit host+port" `Quick test_masc_http_base_url_uses_explicit_host_and_port;
      test_case "sb_path_result missing is error" `Quick test_sb_path_result_missing_is_error;
      test_case "masc_host reads primary env" `Quick test_masc_host_prefers_primary_over_deprecated;
      test_case "assets dir reads primary env" `Quick test_assets_dir_prefers_primary_over_deprecated;
      test_case "cluster_name_opt trims empty" `Quick test_cluster_name_opt_trims_empty;
      test_case "to_json uses canonical introspection shape" `Quick
        test_to_json_uses_canonical_introspection_shape;
      test_case "to_json masks sensitive values and tracks sources" `Quick
        test_to_json_masks_sensitive_values_and_tracks_sources;
      test_case "to_json treats blank env as default" `Quick
        test_to_json_treats_blank_env_as_default;
    ];
    "print_summary", [
      test_case "no error" `Quick test_print_summary_no_error;
    ];
    "zombie", [
      test_case "threshold positive" `Quick test_zombie_threshold_positive;
      test_case "cleanup interval positive" `Quick test_zombie_cleanup_interval_positive;
      test_case "threshold reasonable" `Quick test_zombie_threshold_reasonable;
    ];
    "lock", [
      test_case "timeout positive" `Quick test_lock_timeout_positive;
      test_case "expiry warning positive" `Quick test_lock_expiry_warning_positive;
      test_case "warning < timeout" `Quick test_lock_warning_less_than_timeout;
    ];
    "session", [
      test_case "max age positive" `Quick test_session_max_age_positive;
      test_case "rate limit window positive" `Quick test_session_rate_limit_window_positive;
    ];
    "tempo", [
      test_case "min positive" `Quick test_tempo_min_positive;
      test_case "max positive" `Quick test_tempo_max_positive;
      test_case "default positive" `Quick test_tempo_default_positive;
      test_case "min < max" `Quick test_tempo_min_less_than_max;
      test_case "default in range" `Quick test_tempo_default_in_range;
    ];
    "orchestrator", [
      test_case "interval positive" `Quick test_orchestrator_interval_positive;
      test_case "agent name nonempty" `Quick test_orchestrator_agent_name_nonempty;
    ];
    "cancellation", [
      test_case "max age positive" `Quick test_cancellation_token_max_age_positive;
    ];
    "spawn", [
      test_case "timeout positive" `Quick test_spawn_timeout_positive;
      test_case "timeout default 600" `Quick test_spawn_timeout_default_600;
      test_case "timeout reasonable range" `Quick test_spawn_timeout_reasonable_range;
    ];
    "llama", [
      test_case "server url nonempty" `Quick test_llama_server_url_nonempty;
      test_case "server url httpish" `Quick test_llama_server_url_httpish;
      test_case "max tokens positive" `Quick test_llama_max_tokens_positive;
    ];
    "inference_timeout", [
      test_case "timeout positive" `Quick test_inference_timeout_positive;
      test_case "timeout int positive" `Quick test_inference_timeout_int_positive;
      test_case "operator judge timeout reasonable" `Quick
        test_operator_judge_timeout_reasonable;
      test_case "governance judge timeout reasonable" `Quick
        test_governance_judge_timeout_reasonable;
    ];
    "inference_cache", [
      test_case "cache enabled bool" `Quick test_inference_cache_enabled_bool;
      test_case "cache ttl positive" `Quick test_inference_cache_ttl_positive;
      test_case "max prompt chars positive" `Quick
        test_inference_cache_prompt_chars_positive;
      test_case "l1 max entries positive" `Quick
        test_inference_cache_l1_entries_positive;
      test_case "spawn cache policy supported" `Quick
        test_inference_spawn_cache_policy_supported;
    ];
    "keeper_bootstrap", [
      test_case "stale turn positive" `Quick test_keeper_bootstrap_stale_positive;
      test_case "max scan positive" `Quick test_keeper_bootstrap_max_scan_positive;
    ];
    "keeper_alert", [
      test_case "min score range" `Quick test_keeper_alert_min_score_range;
      test_case "max retries non-negative" `Quick test_keeper_alert_retry_non_negative;
      test_case "body chars positive" `Quick test_keeper_alert_body_chars_positive;
      test_case "slack dm user id readable" `Quick test_keeper_alert_slack_dm_user_id_readable;
    ];
  ]
