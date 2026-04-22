(** Miscellaneous Module Coverage Tests

    Tests for smaller utility modules:
    - Log: logging utilities
    - Config: schema registry helpers
    - Env_config: environment configuration
*)

open Alcotest

module Log = Log
module Config = Masc_mcp.Config
module Env_config = Env_config

(* ============================================================
   Log Tests
   ============================================================ *)

let test_log_level_to_string () =
  check string "debug" "DEBUG" (Log.level_to_string Log.Debug);
  check string "info" "INFO" (Log.level_to_string Log.Info);
  check string "warn" "WARN" (Log.level_to_string Log.Warn);
  check string "error" "ERROR" (Log.level_to_string Log.Error)

let test_log_level_of_string () =
  check bool "debug" true (Log.level_of_string "DEBUG" = Log.Debug);
  check bool "info" true (Log.level_of_string "INFO" = Log.Info);
  check bool "warn" true (Log.level_of_string "WARN" = Log.Warn);
  check bool "warning" true (Log.level_of_string "WARNING" = Log.Warn);
  check bool "error" true (Log.level_of_string "ERROR" = Log.Error);
  check bool "unknown" true (Log.level_of_string "unknown" = Log.Info); (* default *)
  (* partial variant — None on unrecognised, Some on valid *)
  check bool "opt garbage is None" true (Log.level_of_string_opt "debg" = None);
  check bool "opt valid is Some" true
    (Log.level_of_string_opt " DEBUG " = Some Log.Debug)

let test_log_level_of_string_lowercase () =
  check bool "debug lower" true (Log.level_of_string "debug" = Log.Debug);
  check bool "info lower" true (Log.level_of_string "info" = Log.Info);
  check bool "warn lower" true (Log.level_of_string "warn" = Log.Warn)

let test_log_level_to_int () =
  check bool "debug < info" true (Log.level_to_int Log.Debug < Log.level_to_int Log.Info);
  check bool "info < warn" true (Log.level_to_int Log.Info < Log.level_to_int Log.Warn);
  check bool "warn < error" true (Log.level_to_int Log.Warn < Log.level_to_int Log.Error)

let test_log_should_log () =
  Log.set_level Log.Info;
  check bool "info logged at info" true (Log.should_log Log.Info);
  check bool "warn logged at info" true (Log.should_log Log.Warn);
  check bool "error logged at info" true (Log.should_log Log.Error);
  check bool "debug not logged at info" false (Log.should_log Log.Debug)

let test_log_set_level () =
  Log.set_level Log.Error;
  check bool "debug not logged" false (Log.should_log Log.Debug);
  check bool "info not logged" false (Log.should_log Log.Info);
  check bool "warn not logged" false (Log.should_log Log.Warn);
  check bool "error logged" true (Log.should_log Log.Error);
  Log.set_level Log.Info (* Reset to default *)

let test_log_set_level_from_string () =
  Log.set_level_from_string "debug";
  check bool "debug logged" true (Log.should_log Log.Debug);
  Log.set_level_from_string "error";
  check bool "debug not logged" false (Log.should_log Log.Debug);
  Log.set_level Log.Info (* Reset to default *)

let test_log_timestamp () =
  let ts = Log.timestamp () in
  (* Format: YYYY-MM-DD HH:MM:SS *)
  check bool "length >= 19" true (String.length ts >= 19);
  check bool "contains dash" true (String.contains ts '-');
  check bool "contains colon" true (String.contains ts ':')

(* ============================================================
   Config Tests
   ============================================================ *)

let test_config_default () =
  check bool "schemas exist" true (List.length Config.all_tool_schemas > 0)

let test_config_to_json () =
  let names = Config.all_tool_names () in
  check bool "pause in names" true (List.mem "masc_pause" names)

let test_config_of_json () =
  let visible = Config.visible_tool_schemas () in
  check bool "visible non-empty" true (List.length visible > 0)

let test_config_of_json_custom () =
  let names = Config.all_tool_names () in
  check bool "mode tools removed" false (List.mem "masc_switch_mode" names)

let test_config_of_json_invalid () =
  (* masc_pause is auto-classified as Hidden (not on public MCP surface) *)
  check bool "pause hidden (not on public surface)" false
    (Config.is_tool_visible "masc_pause")

(* ============================================================
   Env_config Tests
   ============================================================ *)

let test_env_zombie_threshold () =
  let threshold = Env_config.Zombie.threshold_seconds in
  check bool "positive threshold" true (threshold > 0.0)

let test_env_zombie_cleanup_interval () =
  let interval = Env_config.Zombie.cleanup_interval_seconds in
  check bool "positive interval" true (interval > 0.0)

let test_env_lock_timeout () =
  let timeout = Env_config.Lock.timeout_seconds in
  check bool "positive timeout" true (timeout > 0.0)

let test_env_lock_expiry_warning () =
  let warning = Env_config.Lock.expiry_warning_seconds in
  check bool "positive warning" true (warning > 0.0)

let test_env_session_max_age () =
  let max_age = Env_config.Session.max_age_seconds in
  check bool "positive max_age" true (max_age > 0.0)

let test_env_session_rate_limit () =
  let window = Env_config.Session.rate_limit_window_seconds in
  check bool "positive window" true (window > 0.0)

let test_env_tempo_min () =
  let min = Env_config.Tempo.min_interval_seconds in
  check bool "positive min" true (min > 0.0)

let test_env_tempo_max () =
  let max = Env_config.Tempo.max_interval_seconds in
  check bool "positive max" true (max > 0.0)

let test_env_tempo_default () =
  let default = Env_config.Tempo.default_interval_seconds in
  check bool "positive default" true (default > 0.0)

let test_env_tempo_ordering () =
  let min = Env_config.Tempo.min_interval_seconds in
  let max = Env_config.Tempo.max_interval_seconds in
  check bool "min <= max" true (min <= max)

let test_env_orchestrator_interval () =
  let interval = Env_config.Orchestrator.check_interval_seconds in
  check bool "positive interval" true (interval > 0.0)

let test_env_orchestrator_agent_name () =
  let name = Env_config.Orchestrator.agent_name in
  check bool "non-empty name" true (String.length name > 0)

let test_env_cancellation_max_age () =
  let max_age = Env_config.Cancellation.token_max_age_seconds in
  check bool "positive max_age" true (max_age > 0.0)

let test_env_get_string () =
  let v = Env_config.get_string ~default:"fallback" "NONEXISTENT_VAR_12345" in
  check string "fallback value" "fallback" v

let test_env_get_int () =
  let v = Env_config.get_int ~default:42 "NONEXISTENT_VAR_12345" in
  check int "fallback value" 42 v

let test_env_get_float () =
  let v = Env_config.get_float ~default:3.14 "NONEXISTENT_VAR_12345" in
  check bool "fallback value" true (abs_float (v -. 3.14) < 0.001)

let test_env_get_bool () =
  let v = Env_config.get_bool ~default:true "NONEXISTENT_VAR_12345" in
  check bool "fallback value" true v

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Misc Coverage" [
    "log.level", [
      test_case "to_string" `Quick test_log_level_to_string;
      test_case "of_string" `Quick test_log_level_of_string;
      test_case "of_string lowercase" `Quick test_log_level_of_string_lowercase;
      test_case "to_int ordering" `Quick test_log_level_to_int;
    ];
    "log.logging", [
      test_case "should_log" `Quick test_log_should_log;
      test_case "set_level" `Quick test_log_set_level;
      test_case "set_level_from_string" `Quick test_log_set_level_from_string;
      test_case "timestamp" `Quick test_log_timestamp;
    ];
    "config", [
      test_case "default" `Quick test_config_default;
      test_case "to_json" `Quick test_config_to_json;
      test_case "of_json" `Quick test_config_of_json;
      test_case "of_json custom" `Quick test_config_of_json_custom;
      test_case "of_json invalid" `Quick test_config_of_json_invalid;
    ];
    "env_config.zombie", [
      test_case "threshold" `Quick test_env_zombie_threshold;
      test_case "cleanup_interval" `Quick test_env_zombie_cleanup_interval;
    ];
    "env_config.lock", [
      test_case "timeout" `Quick test_env_lock_timeout;
      test_case "expiry_warning" `Quick test_env_lock_expiry_warning;
    ];
    "env_config.session", [
      test_case "max_age" `Quick test_env_session_max_age;
      test_case "rate_limit" `Quick test_env_session_rate_limit;
    ];
    "env_config.tempo", [
      test_case "min" `Quick test_env_tempo_min;
      test_case "max" `Quick test_env_tempo_max;
      test_case "default" `Quick test_env_tempo_default;
      test_case "ordering" `Quick test_env_tempo_ordering;
    ];
    "env_config.orchestrator", [
      test_case "interval" `Quick test_env_orchestrator_interval;
      test_case "agent_name" `Quick test_env_orchestrator_agent_name;
    ];
    "env_config.cancellation", [
      test_case "max_age" `Quick test_env_cancellation_max_age;
    ];
    "env_config.helpers", [
      test_case "get_string" `Quick test_env_get_string;
      test_case "get_int" `Quick test_env_get_int;
      test_case "get_float" `Quick test_env_get_float;
      test_case "get_bool" `Quick test_env_get_bool;
    ];
  ]
