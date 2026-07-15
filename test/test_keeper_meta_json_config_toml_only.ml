(** TOML-only config: the production JSON parser must NOT read config keys.

    keeper.json is the runtime-state store; keeper.toml is the config SSOT.
    The write side ([keeper_meta_json.ml]) stopped emitting config keys
    (always_allow, mention_targets, allowed_paths, proactive_enabled,
    autoboot_enabled, telemetry_feedback_*), and the read side
    ([keeper_meta_json_parse.ml]) must not resurrect them: a legacy JSON that
    still carries these keys must be ignored so [ensure_keeper_meta]'s TOML
    overlay stays authoritative. Removing the reads without this guard would let
    a stale JSON value silently override the TOML SSOT.

    The test helper [Masc_test_deps.meta_of_json_fixture] intentionally re-injects
    these keys for fixture convenience; that path is test-only and is asserted
    separately so the two behaviors do not drift. *)

open Alcotest
open Masc

(* A JSON meta that carries every retired config key with a non-default value.
   Runtime state (name/agent_name/trace_id/sandbox_profile) is minimal. *)
let legacy_config_json name : Yojson.Safe.t =
  `Assoc
    [ ("name", `String name)
    ; ("agent_name", `String ("agent-" ^ name))
    ; ("trace_id", `String ("trace-" ^ name))
    ; ("sandbox_profile", `String "docker")
    ; (* config keys that must be ignored by the production parser *)
      ("always_allow", `Bool true)
    ; ("mention_targets", `List [ `String "@ghost"; `String "@legacy" ])
    ; ("allowed_paths", `List [ `String "/legacy/path" ])
    ; ("proactive_enabled", `Bool false)
    ; ("autoboot_enabled", `Bool false)
    ; ("telemetry_feedback_enabled", `Bool true)
    ; ("telemetry_feedback_window_hours", `Int 99)
    ]

(* Production parser ignores JSON config keys -> neutral defaults. *)
let test_production_ignores_json_config () =
  match Keeper_meta_json_parse.meta_of_json (legacy_config_json "prod-keeper") with
  | Error e -> Alcotest.failf "meta_of_json failed: %s" e
  | Ok meta ->
    let open Keeper_meta_contract in
    check (option bool) "always_allow ignored (None)" None meta.always_allow;
    check (list string) "mention_targets ignored ([])" [] meta.mention_targets;
    check (list string) "allowed_paths ignored ([])" [] meta.allowed_paths;
    (* proactive default is true; JSON's false must not win *)
    check bool "proactive_enabled ignored (default true)" true meta.proactive.enabled;
    (* autoboot default is true; JSON's false must not win *)
    check bool "autoboot_enabled ignored (default true)" true meta.autoboot_enabled;
    check
      (option bool)
      "telemetry_feedback_enabled ignored (None)"
      None
      meta.telemetry_feedback_enabled;
    check
      (option int)
      "telemetry_feedback_window_hours ignored (None)"
      None
      meta.telemetry_feedback_window_hours

(* Test helper re-injects config for fixture convenience (test-only path). *)
let test_helper_reinjects_config () =
  match Masc_test_deps.meta_of_json_fixture (legacy_config_json "test-keeper") with
  | Error e -> Alcotest.failf "meta_of_json_fixture failed: %s" e
  | Ok meta ->
    let open Keeper_meta_contract in
    check (option bool) "helper injects always_allow" (Some true) meta.always_allow;
    check
      (list string)
      "helper injects mention_targets"
      [ "@ghost"; "@legacy" ]
      meta.mention_targets;
    check (list string) "helper injects allowed_paths" [ "/legacy/path" ] meta.allowed_paths;
    check bool "helper injects proactive_enabled" false meta.proactive.enabled;
    check bool "helper injects autoboot_enabled" false meta.autoboot_enabled;
    check
      (option bool)
      "helper injects telemetry_feedback_enabled"
      (Some true)
      meta.telemetry_feedback_enabled;
    check
      (option int)
      "helper injects telemetry_feedback_window_hours"
      (Some 99)
      meta.telemetry_feedback_window_hours

let () =
  run
    "keeper_meta_json_config_toml_only"
    [ ( "config-is-toml-only"
      , [ test_case "production parser ignores JSON config" `Quick
            test_production_ignores_json_config
        ; test_case "test helper re-injects config" `Quick test_helper_reinjects_config
        ] )
    ]
