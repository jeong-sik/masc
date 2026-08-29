(** Tests for [Keeper_runtime_config] — per-base-path keeper runtime
    tuning loaded from [<resolved config root>/runtime.toml].

    Uses [resolve_overrides] with injected env_lookup to avoid global
    process env dependence. The load_and_apply integration path records
    values in the process-local boot override store. *)

open Alcotest
open Masc

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_base_path f =
  let dir = Filename.temp_file "keeper-runtime-toml" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Unix.mkdir (Filename.concat dir Common.masc_dirname) 0o755;
  Unix.mkdir (Filename.concat dir ".masc/config") 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_toml base_path content =
  let path =
    Filename.concat
      (Filename.concat base_path ".masc/config")
      Config_dir_resolver.runtime_toml_filename
  in
  let oc = open_out path in
  output_string oc content;
  close_out oc

(* Fake env: always returns None (env is "empty"). *)
let empty_env _name = None

(* Fake env with specific vars set. *)
let env_with vars name = List.assoc_opt name vars

(* Parse TOML content into a doc, or fail the test. *)
let parse_or_fail content =
  match Keeper_toml_loader.parse_toml content with
  | Ok doc -> doc
  | Error msg -> failf "TOML parse failed: %s" msg

let with_clean_boot_overrides f =
  Config_boot_overrides.reset_for_tests ();
  Keeper_runtime_resolved.reset_for_tests ();
  Fun.protect
    ~finally:(fun () ->
      Config_boot_overrides.reset_for_tests ();
      Keeper_runtime_resolved.reset_for_tests ())
    f

(* --- Tests using resolve_overrides (pure, no env side effects) --- *)

let test_missing_file_returns_zero () =
  with_base_path @@ fun base_path ->
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok 0 -> ()
  | Ok n -> failf "expected 0 overrides, got %d" n
  | Error msg -> failf "unexpected error: %s" (Keeper_runtime_config.load_failure_to_string msg)


let test_applies_sleep_and_batch_overrides () =
  let doc = parse_or_fail
    "[heartbeat]\n\
     sleep_chunk_sec = 1.5\n\
     [turn]\n\
     batch_limit = 9\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied sleep/batch overrides" 2 count;
  check (option string) "sleep chunk"
    (Some "1.5")
    (List.assoc_opt "MASC_KEEPER_SLEEP_CHUNK_SEC" overrides);
  check (option string) "batch limit"
    (Some "9")
    (List.assoc_opt "MASC_KEEPER_BATCH_LIMIT" overrides)

let test_applies_turn_execution_overrides () =
  let doc = parse_or_fail
    "[turn]\n\
     temperature = 0.65\n\
     stream_idle_timeout_sec = 90\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied 2" 2 count;
  check (option string) "temperature"
    (Some "0.65")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_TEMP" overrides);
  check (option string) "stream idle timeout"
    (Some "90")
    (List.assoc_opt "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" overrides)

let test_applies_health_overrides () =
  let doc =
    parse_or_fail
      "[health]\n\
       durable_queue_stale_sec = 45.5\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied health override count" 1 count;
  check (option string) "durable queue stale threshold"
    (Some "45.5")
    (List.assoc_opt "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC" overrides)

(* The whole [wire_capture] table resolves, not just its switch. [enabled] was
   [Toml_and_env] while [retention_days] and [max_bytes] were [Env_only], and
   because [wire_capture] is an owned namespace an unmapped sibling is rejected
   rather than ignored — so writing the obvious three keys together took the
   server down at boot. This fails if either sibling is returned to [Env_only].
   Live evidence: the keys sat commented out in runtime.toml with the FATAL
   recorded above them. *)
let test_applies_wire_capture_overrides () =
  let doc =
    parse_or_fail
      "[wire_capture]\n\
       enabled = true\n\
       retention_days = 7\n\
       max_bytes = 536870912\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "all three wire-capture keys apply" 3 count;
  check (option string) "enabled"
    (Some "true")
    (List.assoc_opt "MASC_KEEPER_WIRE_CAPTURE" overrides);
  check (option string) "retention days"
    (Some "7")
    (List.assoc_opt "MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS" overrides);
  check (option string) "max bytes"
    (Some "536870912")
    (List.assoc_opt "MASC_KEEPER_WIRE_CAPTURE_MAX_BYTES" overrides)

(* RFC-0297 P0-1: the three lifecycle kill-switches must map TOML ->
   canonical env instead of being silently dropped. Before the key_to_env
   mappings existed, [reactive]/[proactive]/[autonomous] enabled were never
   visited by load_and_apply and vanished. *)
let test_applies_lifecycle_enabled_overrides () =
  let doc = parse_or_fail
    "[reactive]\n\
     enabled = false\n\
     [proactive]\n\
     enabled = false\n\
     [autonomous]\n\
     enabled = true\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied three lifecycle enabled overrides" 3 count;
  check (option string) "reactive enabled maps to canonical env"
    (Some "false")
    (List.assoc_opt "MASC_KEEPER_REACTIVE_ENABLED" overrides);
  check (option string) "proactive enabled maps to canonical env"
    (Some "false")
    (List.assoc_opt "MASC_KEEPER_PROACTIVE_ENABLED" overrides);
  check (option string) "autonomous enabled maps to canonical env"
    (Some "true")
    (List.assoc_opt "MASC_KEEPER_AUTONOMOUS_ENABLED" overrides)

let test_parse_error_returns_error () =
  with_base_path @@ fun base_path ->
  write_toml base_path "this is not valid TOML [[[\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok _ -> fail "expected parse error"
  | Error _ -> ()

let test_current_schema_unknown_keeper_key_is_rejected () =
  let report =
    Keeper_runtime_config.validate_doc
      (parse_or_fail "[keeper_settings]\nschema_version = 1\n[turn]\ntemperatur = 0.4\n")
  in
  check bool "current-schema typo is invalid" false
    (Keeper_runtime_config.validation_report_is_valid report);
  match report.issues with
  | [ issue ] ->
    check string "unknown key retained" "turn.temperatur" issue.key;
    check bool "classified unknown" true
      (issue.kind = Keeper_runtime_config.Unknown_key);
    check bool "current schema rejects" true
      (issue.severity = Keeper_runtime_config.Error)
  | issues -> failf "expected one issue, got %d" (List.length issues)

let test_retired_keeper_key_is_rejected () =
  let report =
    Keeper_runtime_config.validate_doc
      (parse_or_fail "[turn]\ncapacity_limit = 3\n")
  in
  check bool "retired key is invalid" false
    (Keeper_runtime_config.validation_report_is_valid report);
  match report.issues with
  | [ issue ] ->
    check bool "classified retired" true
      (issue.kind = Keeper_runtime_config.Retired_key);
    check bool "retired key rejects" true
      (issue.severity = Keeper_runtime_config.Error)
  | issues -> failf "expected one issue, got %d" (List.length issues)

let test_future_schema_unknown_keeper_key_is_warning () =
  let report =
    Keeper_runtime_config.validate_doc
      (parse_or_fail "[keeper_settings]\nschema_version = 2\n[turn]\nfuture_budget = 7\n")
  in
  check bool "future schema remains saveable" true
    (Keeper_runtime_config.validation_report_is_valid report);
  check bool "forward schema is explicit" true report.forward_schema;
  match report.issues with
  | [ issue ] ->
    check bool "future key remains unknown" true
      (issue.kind = Keeper_runtime_config.Unknown_key);
    check bool "future key warns" true
      (issue.severity = Keeper_runtime_config.Warning)
  | issues -> failf "expected one warning, got %d" (List.length issues)

let test_unrelated_runtime_namespaces_are_not_claimed () =
  let report =
    Keeper_runtime_config.validate_doc
      (parse_or_fail
         "[runtime]\ndefault = \"provider.model\"\n[models.sample]\napi-name = \"sample\"\n")
  in
  check bool "other loader namespaces remain valid" true
    (Keeper_runtime_config.validation_report_is_valid report);
  check int "no Keeper issues" 0 (List.length report.issues)

let test_runtime_provider_binding_under_keeper_namespace_is_not_claimed () =
  let report =
    Keeper_runtime_config.validate_doc
      (parse_or_fail
         "[turn.some-model]\nbase-url = \"https://example.invalid/v1\"\n")
  in
  check bool "runtime provider subtable remains valid" true
    (Keeper_runtime_config.validation_report_is_valid report);
  check int "provider binding has no Keeper issues" 0 (List.length report.issues)

let test_load_and_apply_records_boot_override () =
  match Sys.getenv_opt "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" with
  | Some _ -> ()
  | None ->
    with_clean_boot_overrides @@ fun () ->
    with_base_path @@ fun base_path ->
    write_toml base_path "[turn]\nstream_idle_timeout_sec = 42\n";
    match Keeper_runtime_config.load_and_apply ~base_path with
    | Error msg -> failf "unexpected error: %s" (Keeper_runtime_config.load_failure_to_string msg)
    | Ok n ->
      check int "applied count" 1 n;
      check (option string) "boot override stored"
        (Some "42")
        (Config_boot_overrides.get_opt "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC");
      Keeper_runtime_resolved.reset_for_tests ();
      check (option (float 0.0001)) "runtime resolver sees boot override"
        (Some 42.0)
        (Keeper_runtime_resolved.stream_idle_timeout_sec ())



let with_env name value f =
  let prev = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let test_explicit_config_dir_wins_over_base_path () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  with_base_path @@ fun override_root ->
  write_toml base_path "[turn]\nstream_idle_timeout_sec = 42\n";
  write_toml override_root "[turn]\nstream_idle_timeout_sec = 99\n";
  let override_config_dir = Filename.concat override_root ".masc/config" in
  with_env "MASC_CONFIG_DIR" (Some override_config_dir) @@ fun () ->
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "unexpected error: %s" (Keeper_runtime_config.load_failure_to_string msg)
  | Ok n ->
    check int "applied count" 1 n;
    check (option string) "explicit config dir stored"
      (Some "99")
      (Config_boot_overrides.get_opt "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC")

let test_float_value_round_trip () =
  let doc = parse_or_fail
    "[turn]\nstream_idle_timeout_sec = 120.5\n"
  in
  let _, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check (option string) "float preserved"
    (Some "120.5")
    (List.assoc_opt "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" overrides)

let test_resolved_runtime_freezes_toml_values_after_init () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path
    "[turn]\n\
     stream_idle_timeout_sec = 50\n";
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" (Keeper_runtime_config.load_failure_to_string msg)
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  Config_boot_overrides.set "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" "90";
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "stream idle timeout frozen from toml"
    (Some 50.0) runtime.stream_idle_timeout_sec.value;
  check string "stream idle timeout source"
    "toml"
    (Keeper_runtime_resolved.source_to_string runtime.stream_idle_timeout_sec.source)

let test_resolved_stream_idle_timeout_defaults_to_failsafe_floor () =
  (* RFC-0345 / #25128: with no explicit env/toml value the resolver substitutes
     the fail-safe liveness floor (not [None]) so AGENT_CORE enforces a bound and a hung
     stream cannot freeze the lane forever. Reverting the floor (back to [None])
     makes this fail. *)
  with_clean_boot_overrides @@ fun () ->
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "stream idle timeout defaults to fail-safe floor"
    (Some Keeper_runtime_resolved.stream_idle_failsafe_floor_sec)
    runtime.stream_idle_timeout_sec.value;
  check (option (float 0.0001)) "accessor returns the floor when unset"
    (Some Keeper_runtime_resolved.stream_idle_failsafe_floor_sec)
    (Keeper_runtime_resolved.stream_idle_timeout_sec ());
  check string "stream idle timeout floor source"
    "failsafe_floor"
    (Keeper_runtime_resolved.source_to_string runtime.stream_idle_timeout_sec.source)

let test_resolved_first_event_timeout_defaults_to_failsafe_floor () =
  (* RFC-AC-037: with no explicit env/toml value the resolver substitutes the
     silent-prefill liveness ceiling (not [None]). Without it AGENT_CORE's
     first-event resolver falls through to the much shorter inter-line idle
     value and any provider that prefills silently past it dies at
     awaiting_first_event (canary-multiturn-localmlx, 9/9 on 2026-08-16). *)
  with_clean_boot_overrides @@ fun () ->
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "first-event timeout defaults to fail-safe floor"
    (Some Keeper_runtime_resolved.first_event_failsafe_floor_sec)
    runtime.first_event_timeout_sec.value;
  check (option (float 0.0001)) "accessor returns the floor when unset"
    (Some Keeper_runtime_resolved.first_event_failsafe_floor_sec)
    (Keeper_runtime_resolved.first_event_timeout_sec ());
  check string "first-event timeout floor source"
    "failsafe_floor"
    (Keeper_runtime_resolved.source_to_string runtime.first_event_timeout_sec.source)

let test_resolved_first_event_timeout_uses_toml () =
  (* End-to-end pin for the registry-driven mapping: runtime.toml
     [turn.first_event_timeout_sec] must reach the resolver as
     MASC_KEEPER_FIRST_EVENT_TIMEOUT_SEC. *)
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nfirst_event_timeout_sec = 480\n";
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" (Keeper_runtime_config.load_failure_to_string msg)
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "first-event timeout from toml"
    (Some 480.0) runtime.first_event_timeout_sec.value;
  check string "first-event timeout source"
    "toml"
    (Keeper_runtime_resolved.source_to_string runtime.first_event_timeout_sec.source)

let test_resolved_stream_idle_timeout_uses_toml () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nstream_idle_timeout_sec = 75\n";
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" (Keeper_runtime_config.load_failure_to_string msg)
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "stream idle timeout from toml"
    (Some 75.0) runtime.stream_idle_timeout_sec.value;
  check string "stream idle timeout source"
    "toml"
    (Keeper_runtime_resolved.source_to_string runtime.stream_idle_timeout_sec.source)

let test_resolved_runtime_prefers_env_over_toml () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nstream_idle_timeout_sec = 50\n";
  with_env "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" (Some "55") @@ fun () ->
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" (Keeper_runtime_config.load_failure_to_string msg)
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "env stream idle timeout wins"
    (Some 55.0) runtime.stream_idle_timeout_sec.value;
  check string "env source"
    "env"
    (Keeper_runtime_resolved.source_to_string runtime.stream_idle_timeout_sec.source)

(* #27416: the provider-call deadline knob must survive a restart that
   forgets the env var — TOML is the durable channel, env the override. *)
let test_applies_provider_call_deadline_override () =
  let doc = parse_or_fail "[turn]\nprovider_call_deadline_sec = 900\n" in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied 1" 1 count;
  check (option string) "provider call deadline"
    (Some "900")
    (List.assoc_opt "MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC" overrides)

let test_provider_call_deadline_invalid_toml_returns_error () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nprovider_call_deadline_sec = 0\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok _ -> fail "expected non-positive provider call deadline to be rejected"
  | Error failure ->
    check bool "classified as a validate failure" true
      (failure.Keeper_runtime_config.kind = Keeper_runtime_config.Validate);
    check bool "diagnostic names the TOML key and declared range" true
      (String.ends_with
         ~suffix:
           "turn.provider_call_deadline_sec: value is outside the declared range [30, 3600]"
         (Keeper_runtime_config.load_failure_to_string failure))

let test_resolved_provider_call_deadline_uses_toml () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nprovider_call_deadline_sec = 900\n";
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" (Keeper_runtime_config.load_failure_to_string msg)
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "provider call deadline from toml"
    (Some 900.0) runtime.provider_call_deadline_sec.value;
  check string "provider call deadline source"
    "toml"
    (Keeper_runtime_resolved.source_to_string runtime.provider_call_deadline_sec.source)

let test_resolved_provider_call_deadline_prefers_env () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nprovider_call_deadline_sec = 900\n";
  with_env "MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC" (Some "1200") @@ fun () ->
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" (Keeper_runtime_config.load_failure_to_string msg)
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "env provider call deadline wins"
    (Some 1200.0) runtime.provider_call_deadline_sec.value;
  check string "env source"
    "env"
    (Keeper_runtime_resolved.source_to_string runtime.provider_call_deadline_sec.source)

let test_resolved_stream_idle_timeout_does_not_clamp () =
  with_clean_boot_overrides @@ fun () ->
  with_env "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" (Some "3600") @@ fun () ->
  Keeper_runtime_resolved.init ();
  check (option (float 0.0001)) "explicit value is preserved"
    (Some 3600.0)
    (Keeper_runtime_resolved.stream_idle_timeout_sec ())

let test_resolved_stream_idle_timeout_env_below_floor_preserved () =
  (* Override precedence: an explicit value BELOW the floor is honoured verbatim.
     The resolver substitutes the floor only for [None]; it does not clamp an
     operator value up to the floor. A [max env floor] mutation fails this. *)
  with_clean_boot_overrides @@ fun () ->
  with_env "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" (Some "30") @@ fun () ->
  Keeper_runtime_resolved.init ();
  check (option (float 0.0001)) "explicit sub-floor value preserved (no clamp-up)"
    (Some 30.0)
    (Keeper_runtime_resolved.stream_idle_timeout_sec ())

let expect_stream_idle_timeout_env_config_error raw =
  with_clean_boot_overrides @@ fun () ->
  with_env "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" (Some raw) @@ fun () ->
  match Keeper_runtime_resolved.init () with
  | () -> fail "expected invalid stream idle timeout to fail"
  | exception Env_config_core.Config_error message ->
    check string "diagnostic names the invalid stream idle setting"
      (Printf.sprintf
         "invalid MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC=%S (expected a finite, positive number of seconds)"
         raw)
      message

let test_resolved_stream_idle_timeout_invalid_env_fails_loud () =
  expect_stream_idle_timeout_env_config_error "not-a-timeout"

let test_resolved_stream_idle_timeout_empty_env_fails_loud () =
  expect_stream_idle_timeout_env_config_error ""

let test_resolved_stream_idle_timeout_whitespace_env_fails_loud () =
  expect_stream_idle_timeout_env_config_error "   "

let test_stream_idle_timeout_invalid_toml_returns_error () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nstream_idle_timeout_sec = 0\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok _ -> fail "expected non-positive stream idle timeout to be rejected"
  | Error failure ->
    check bool "classified as a validate failure" true
      (failure.Keeper_runtime_config.kind = Keeper_runtime_config.Validate);
    check bool "diagnostic names the TOML key" true
      (String.ends_with
         ~suffix:
           "turn.stream_idle_timeout_sec: expected a finite, positive number of seconds"
         (Keeper_runtime_config.load_failure_to_string failure))

let test_stream_idle_timeout_toml_wrong_type_returns_error () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nstream_idle_timeout_sec = \"120\"\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok _ -> fail "expected string stream idle timeout to be rejected"
  | Error failure ->
    check bool "classified as a validate failure" true
      (failure.Keeper_runtime_config.kind = Keeper_runtime_config.Validate);
    check bool "diagnostic requires a numeric TOML value" true
      (String.ends_with
         ~suffix:
           "turn.stream_idle_timeout_sec: expected a numeric TOML value"
         (Keeper_runtime_config.load_failure_to_string failure))

(* The bootstrap counter labels itself from load_failure_kind. Its help text
   enumerates the labels, so a constructor added without a label — or a label
   added without a constructor — has to break here rather than at whatever
   dashboard reads the metric. *)
let test_every_failure_kind_has_a_label () =
  check (list string) "labels cover the constructors"
    [ "read_error"; "parse_error"; "validate_error" ]
    Keeper_runtime_config.load_failure_kind_labels;
  check int "one label per constructor"
    (List.length Keeper_runtime_config.all_load_failure_kinds)
    (List.length Keeper_runtime_config.load_failure_kind_labels)
;;

let test_rendering_keeps_the_verb_prefix () =
  List.iter
    (fun (kind, verb) ->
      let rendered =
        Keeper_runtime_config.load_failure_to_string
          { Keeper_runtime_config.kind; message = "x: y" }
      in
      check bool
        (verb ^ " prefix preserved")
        true
        (String.starts_with ~prefix:(verb ^ " ") rendered))
    [ Keeper_runtime_config.Read, "read"
    ; Keeper_runtime_config.Parse, "parse"
    ; Keeper_runtime_config.Validate, "validate"
    ]
;;

let test_removed_toml_overlay_is_pending_restart () =
  with_clean_boot_overrides @@ fun () ->
  Config_boot_overrides.set "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" "42";
  let empty_doc = parse_or_fail "" in
  let open Yojson.Safe.Util in
  let setting =
    Keeper_runtime_config.settings_projection_to_yojson empty_doc
    |> to_list
    |> List.find (fun row ->
      String.equal
        (row |> member "env" |> to_string)
        "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC")
  in
  check string
    "removed TOML value remains pending until restart"
    "pending_restart"
    (setting |> member "application_status" |> to_string);
  let overlay = Keeper_runtime_config.overlay_application_to_yojson empty_doc in
  check bool
    "removed boot overlay requires restart"
    true
    (overlay |> member "requires_restart" |> to_bool);
  check bool
    "removed key is included in pending overlay summary"
    true
    (overlay
     |> member "pending_keys"
     |> to_list
     |> List.exists (function
       | `String "turn.stream_idle_timeout_sec" -> true
       | _ -> false))
;;

let test_settings_projection_uses_typed_effective_values () =
  let open Yojson.Safe.Util in
  let rows =
    Keeper_runtime_config.settings_projection_to_yojson (parse_or_fail "")
    |> to_list
  in
  let find env_name =
    List.find (fun row -> String.equal (row |> member "env" |> to_string) env_name) rows
  in
  let snapshot = find "MASC_KEEPER_SNAPSHOT_SEC" in
  check string "snapshot projection uses clamped runtime value"
    (string_of_int Env_config_keeper.KeeperRuntime.snapshot_sec)
    (snapshot |> member "effective_value" |> to_string);
  check bool "snapshot projection has no normalization error" true
    (snapshot |> member "effective_error" = `Null);
  let deadline = find "MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC" in
  let expected_deadline =
    match Env_config_keeper.KeeperKeepalive.provider_call_deadline_sec_override with
    | Some value -> Printf.sprintf "%g" value
    | None -> "(none)"
  in
  check string "deadline projection uses typed runtime value" expected_deadline
    (deadline |> member "effective_value" |> to_string)
;;

(* #28413. Adding a registry row gets a setting listed, but the effective-value
   projector is a separate match on env_name whose fallthrough raises
   "no typed effective-value projector for ...". A row without one still appears
   in the operator panel -- with a null value and an error string -- which reads
   as a broken setting rather than a missing projector. This asserts the row is
   both present and readable, and that the panel reports the same string the
   prompt builder resolves. *)
let test_wake_prompt_is_readable_in_the_settings_projection () =
  let open Yojson.Safe.Util in
  let rows =
    Keeper_runtime_config.settings_projection_to_yojson
      (parse_or_fail "[autonomous]\nwake_prompt = \"what changed since your last turn?\"\n")
    |> to_list
  in
  match
    List.find_opt
      (fun row ->
         String.equal
           (row |> member "env" |> to_string)
           "MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT")
      rows
  with
  | None -> fail "the wake prompt is absent from the operator settings projection"
  | Some row ->
    check string "the panel exposes the TOML key operators edit"
      "autonomous.wake_prompt"
      (row |> member "key" |> to_string);
    check bool "the projection carries no error" true
      (row |> member "effective_error" = `Null);
    check string "the configured value is echoed back"
      "what changed since your last turn?"
      (row |> member "configured_value" |> to_string);
    check string "the effective value is the one the prompt builder resolves"
      (Env_config_keeper.KeeperAutonomous.wake_prompt ())
      (row |> member "effective_value" |> to_string);
    check bool "the consumer is named" true
      (row
       |> member "consumers"
       |> to_list
       |> List.exists (fun c -> to_string c = "Keeper_unified_prompt"))
;;

(* PR #28225 review (comment 3761300276): the raw-config preview computed
   can_save from the keeper schema alone, but the raw-save path also runs the
   runtime parser (Runtime.save_config_text). A config that parses and passes
   the keeper schema but names an unknown [runtime] default therefore advertised
   can_save=true while save was guaranteed to reject it. Runtime.validate_config_text
   now runs that runtime precondition and shares it with the writer, so preview
   and save cannot disagree. *)
let test_preview_precondition_matches_save () =
  let schema_ok_runtime_bad = "[runtime]\ndefault = \"ghost-runtime\"\n" in
  (match Keeper_runtime_config.validate_source_text schema_ok_runtime_bad with
   | Error msg -> failf "keeper schema unexpectedly rejected the text: %s" msg
   | Ok report ->
     check
       bool
       "keeper schema alone reports the text as valid (the old can_save source)"
       true
       (Keeper_runtime_config.validation_report_is_valid report));
  with_base_path (fun base_path ->
    let runtime_config_path =
      Filename.concat
        (Filename.concat base_path ".masc/config")
        Config_dir_resolver.runtime_toml_filename
    in
    let validate =
      Runtime.validate_config_text ~runtime_config_path schema_ok_runtime_bad
    in
    let save =
      Runtime.save_config_text ~runtime_config_path schema_ok_runtime_bad
    in
    check
      bool
      "runtime precondition rejects the unknown [runtime] default"
      true
      (Result.is_error validate);
    check
      bool
      "preview validation and save agree on the same input"
      true
      (Result.is_error validate = Result.is_error save))
;;

let () =
  run "runtime_toml_overrides"
    [ ( "resolve_overrides"
      , [ test_case "missing file returns 0 overrides" `Quick test_missing_file_returns_zero
        ; test_case "applies sleep/batch overrides" `Quick test_applies_sleep_and_batch_overrides
        ; test_case "applies turn execution overrides" `Quick test_applies_turn_execution_overrides
        ; test_case "applies health overrides" `Quick test_applies_health_overrides
        ; test_case "applies the whole wire_capture table" `Quick
            test_applies_wire_capture_overrides
        ; test_case "applies lifecycle enabled overrides (RFC-0297 P0-1)" `Quick test_applies_lifecycle_enabled_overrides
        ; test_case "parse error returns Error" `Quick test_parse_error_returns_error
        ; test_case "current schema rejects unknown Keeper key" `Quick
            test_current_schema_unknown_keeper_key_is_rejected
        ; test_case "retired Keeper key is rejected" `Quick
            test_retired_keeper_key_is_rejected
        ; test_case "future schema preserves unknown key as warning" `Quick
            test_future_schema_unknown_keeper_key_is_warning
        ; test_case "unrelated namespaces remain separately owned" `Quick
            test_unrelated_runtime_namespaces_are_not_claimed
        ; test_case "provider binding under Keeper namespace remains separately owned" `Quick
            test_runtime_provider_binding_under_keeper_namespace_is_not_claimed
        ; test_case "load_and_apply records boot override" `Quick test_load_and_apply_records_boot_override
        ; test_case "every failure kind has a label" `Quick
            test_every_failure_kind_has_a_label
        ; test_case "rendering keeps the verb prefix" `Quick
            test_rendering_keeps_the_verb_prefix
        ; test_case "removed TOML overlay is pending restart" `Quick
            test_removed_toml_overlay_is_pending_restart
        ; test_case "settings projection uses typed effective values" `Quick
            test_settings_projection_uses_typed_effective_values
        ; test_case "explicit MASC_CONFIG_DIR wins over base path" `Quick test_explicit_config_dir_wins_over_base_path
        ; test_case "float value round trip" `Quick test_float_value_round_trip
        ; test_case "resolved runtime freezes toml values after init" `Quick test_resolved_runtime_freezes_toml_values_after_init
        ; test_case "resolved stream idle timeout defaults to fail-safe floor" `Quick test_resolved_stream_idle_timeout_defaults_to_failsafe_floor
        ; test_case "resolved first-event timeout defaults to fail-safe floor" `Quick test_resolved_first_event_timeout_defaults_to_failsafe_floor
        ; test_case "resolved first-event timeout uses toml" `Quick test_resolved_first_event_timeout_uses_toml
        ; test_case "resolved stream idle timeout uses toml" `Quick test_resolved_stream_idle_timeout_uses_toml
        ; test_case "invalid stream idle TOML returns Error" `Quick test_stream_idle_timeout_invalid_toml_returns_error
        ; test_case "wrong-type stream idle TOML returns Error" `Quick test_stream_idle_timeout_toml_wrong_type_returns_error
        ; test_case "applies provider call deadline override (#27416)" `Quick
            test_applies_provider_call_deadline_override
        ; test_case "invalid provider call deadline TOML returns Error" `Quick
            test_provider_call_deadline_invalid_toml_returns_error
        ; test_case "resolved provider call deadline uses toml" `Quick
            test_resolved_provider_call_deadline_uses_toml
        ; test_case "resolved provider call deadline prefers env" `Quick
            test_resolved_provider_call_deadline_prefers_env
        ; test_case "resolved runtime prefers env over toml" `Quick test_resolved_runtime_prefers_env_over_toml
        ; test_case "resolved stream idle timeout does not clamp" `Quick test_resolved_stream_idle_timeout_does_not_clamp
        ; test_case "resolved stream idle timeout env below floor preserved" `Quick test_resolved_stream_idle_timeout_env_below_floor_preserved
        ; test_case "invalid stream idle env fails loud" `Quick test_resolved_stream_idle_timeout_invalid_env_fails_loud
        ; test_case "empty stream idle env fails loud" `Quick test_resolved_stream_idle_timeout_empty_env_fails_loud
        ; test_case "whitespace stream idle env fails loud" `Quick test_resolved_stream_idle_timeout_whitespace_env_fails_loud
        ; test_case "preview precondition matches save (#28225)" `Quick
            test_preview_precondition_matches_save
        ; test_case "wake prompt is readable in the settings panel (#28413)" `Quick
            test_wake_prompt_is_readable_in_the_settings_projection
        ] )
    ]
