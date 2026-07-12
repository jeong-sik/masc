(** Test suite for Keeper_supervisor — fiber liveness tracking and recovery.
    Pure tests for backoff/helpers. Fiber health queries now delegate to
    Keeper_registry (tested in test_keeper_registry.ml). *)

open Alcotest
module Sup = Masc.Keeper_supervisor
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module Keeper_types_profile = Masc.Keeper_types_profile
module Reg = Masc.Keeper_registry
module KT = Keeper_types
module KR = Masc.Keeper_runtime
module AQ = Masc.Keeper_approval_queue
module KSM = Keeper_state_machine
module KLH = Masc.Keeper_lifecycle_hooks
module FD = Keeper_fd_pressure
module KA = Masc.Keeper_keepalive
module KFP = Keeper_failure_policy
module KSP = Masc.Keeper_supervisor_self_preservation
module KSR = Masc.Keeper_supervisor_reconcile_keepalive
module Lane = Masc.Keeper_lane
module Shutdown_finalize = Masc.Keeper_shutdown_finalize
module Shutdown_store = Masc.Keeper_shutdown_store
module Shutdown_types = Masc.Keeper_shutdown_types
module Subprocess_registry = Masc.Keeper_subprocess_registry
module Tombstone_cleanup = Masc.Keeper_supervisor_cleanup_tombstone
module Process_switch = Masc.Keeper_process_switch
module Tool_accumulator = Masc.Keeper_tool_emission_hook
module Latched_reason = Keeper_latched_reason

let supervisor_agent_name = Sup.supervisor_agent_name

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_supervisor_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then
    Fs_compat.set_fs (Eio.Stdenv.fs env)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let rec wait_until ~clock ~deadline predicate =
  if predicate ()
  then true
  else if Eio.Time.now clock >= deadline
  then false
  else (
    Eio.Time.sleep clock 0.01;
    wait_until ~clock ~deadline predicate)

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let resolve_done_for_test reg value =
  ignore (Reg.resolve_done reg ~source:"test_fixture" value);
  match
    Lane.reject_before_start reg.lane ~reason:(Failure "synthetic terminal fixture")
  with
  | Ok () -> ()
  | Error error -> fail (Lane.start_error_to_string error)

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

let with_env name value f =
  let original = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () -> restore_env name original)
    (fun () ->
      Unix.putenv name value;
      f ())

let with_config_dir f =
  let dir = temp_dir () in
  let config_dir = Filename.concat dir "config" in
  mkdir_p (Filename.concat config_dir "keepers");
  mkdir_p (Filename.concat config_dir "personas");
  let original = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" original;
      Config_dir_resolver.reset ();
      cleanup_dir dir)
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      f config_dir)

let write_keeper_toml config_dir ~name =
  write_file
    (Filename.concat (Filename.concat config_dir "keepers") (name ^ ".toml"))
    (Printf.sprintf
       {|
[keeper]
name = "%s"
goal = "test keeper"
sandbox_profile = "local"
|}
       name)

let write_keeper_toml_without_goal config_dir ~name ~instructions =
  write_file
    (Filename.concat (Filename.concat config_dir "keepers") (name ^ ".toml"))
    (Printf.sprintf
       {|
[keeper]
name = "%s"
sandbox_profile = "local"
proactive_enabled = false
instructions = "%s"
|}
       name instructions);
  Keeper_types_profile.invalidate_keeper_profile_defaults_cache name

let write_empty_keeper_toml_without_goal config_dir ~name =
  write_file
    (Filename.concat (Filename.concat config_dir "keepers") (name ^ ".toml"))
    (Printf.sprintf
       {|
[keeper]
name = "%s"
sandbox_profile = "local"
proactive_enabled = false
|}
       name);
  Keeper_types_profile.invalidate_keeper_profile_defaults_cache name

let with_restart_launch_noop f =
  Sup.with_restart_launch_noop_for_test f

let policy_decision_exn reason =
  match Sup.failure_reason_policy_decision_for_test reason with
  | Some decision -> decision
  | None -> fail "expected supervisor policy decision"

(* ── Pure tests: backoff_delay ──────────────────────────── *)

let test_backoff_delay_attempt_0 () =
  (* Default base: 10.0s *)
  let d = Sup.backoff_delay 0 in
  check (float 0.1) "attempt 0 = base" 10.0 d

let test_backoff_delay_exponential () =
  let d1 = Sup.backoff_delay 1 in
  let d2 = Sup.backoff_delay 2 in
  let d3 = Sup.backoff_delay 3 in
  check (float 0.1) "attempt 1 = 2*base" 20.0 d1;
  check (float 0.1) "attempt 2 = 4*base" 40.0 d2;
  check (float 0.1) "attempt 3 = 8*base" 80.0 d3

let test_backoff_delay_cap () =
  (* Default max: 300.0s. 2^5 * 10 = 320 > 300 *)
  let d5 = Sup.backoff_delay 5 in
  check (float 0.1) "attempt 5 capped at 300" 300.0 d5;
  let d10 = Sup.backoff_delay 10 in
  check (float 0.1) "attempt 10 capped at 300" 300.0 d10

let test_auto_resume_first_delay_capped () =
  let delay =
    Sup.next_auto_resume_after_sec
      ~initial_sec:7200.0 ~max_sec:3600.0 None
  in
  check (option (float 0.1)) "first delay capped at max"
    (Some 3600.0) delay

let test_auto_resume_disabled () =
  let delay =
    Sup.next_auto_resume_after_sec
      ~initial_sec:0.0 ~max_sec:3600.0 (Some 1800.0)
  in
  check (option (float 0.1)) "initial <= 0 disables auto-resume"
    None delay

let test_supervisor_policy_pauses_watchdog_provider_timeout_loop () =
  let decision =
    policy_decision_exn (Some (Reg.Provider_timeout_loop { count = 3 }))
  in
  check string "scope" "keeper_liveness"
    (KFP.failure_scope_to_label decision.failure_scope);
  check string "lifecycle" "pause_keeper"
    (KFP.lifecycle_effect_to_label decision.lifecycle_effect);
  check string "circuit" "operator_breaker"
    (KFP.circuit_effect_to_label decision.circuit_effect);
  check bool "keeper death denied" false decision.keeper_death_allowed;
  check string "reason" "keeper_liveness_lost_after_timeout" decision.reason

let test_supervisor_policy_pauses_stale_storm () =
  let decision =
    policy_decision_exn (Some (Reg.Stale_termination_storm { count = 5 }))
  in
  check string "scope" "fleet" (KFP.failure_scope_to_label decision.failure_scope);
  check string "lifecycle" "pause_keeper"
    (KFP.lifecycle_effect_to_label decision.lifecycle_effect);
  check bool "keeper death denied" false decision.keeper_death_allowed;
  check string "reason" "stale_termination_storm:5" decision.reason

let test_supervisor_policy_restarts_stale_turn () =
  let decision =
    policy_decision_exn
      (Some
         (Reg.Stale_turn_timeout
            (* formerly In_turn_hung (retired); any stale_kill_class drives the
               same keeper-liveness restart decision. *)
            (Reg.Mid_turn_no_progress
               { active_seconds = 60.0
               ; since_progress_seconds = 45.0
               ; progress_timeout_threshold = 30.0
               ; last_progress_kind = None
               })))
  in
  check string "scope" "keeper_liveness"
    (KFP.failure_scope_to_label decision.failure_scope);
  check string "lifecycle" "restart_keeper"
    (KFP.lifecycle_effect_to_label decision.lifecycle_effect);
  check bool "keeper death allowed" true decision.keeper_death_allowed

(* Typed runtime-exhaustion retryability bridge. The consumer now reads the
   carried [Keeper_meta_contract.runtime_exhaustion_reason] instead of
   reparsing the stringified [code]; this pins the polarity, including the
   correction of transient/connectivity reasons from terminal to retryable. *)
let provider_runtime_error_of_reason reason =
  Reg.Provider_runtime_error
    { code = "ignored_by_typed_path"
    ; detail = "test"
    ; provider_id = None
    ; http_status = None
    ; runtime_id = None
    ; reason = Some reason
    }

let test_supervisor_policy_runtime_exhausted_retryable_reasons () =
  let retryable_reasons =
    [ Keeper_meta_contract.Candidates_filtered_after_cycles
    ; Keeper_meta_contract.Max_turns_exceeded
    ; Keeper_meta_contract.Capacity_exhausted
    ; Keeper_meta_contract.Connection_refused
    ; Keeper_meta_contract.Dns_failure
    ; Keeper_meta_contract.No_providers_available
    ; Keeper_meta_contract.All_providers_failed
    ; Keeper_meta_contract.Structural_attempt_timeout { detail = "30" }
    ]
  in
  List.iter
    (fun reason ->
       let decision =
         policy_decision_exn (Some (provider_runtime_error_of_reason reason))
       in
       check string
         ("retryable reason -> soft_fail_turn ("
          ^ Keeper_meta_contract.runtime_exhaustion_summary reason ^ ")")
         "soft_fail_turn"
         (KFP.lifecycle_effect_to_label decision.lifecycle_effect);
       check string "reason label" "runtime_exhausted_retryable" decision.reason)
    retryable_reasons

let test_supervisor_policy_runtime_exhausted_terminal_reasons () =
  let terminal_reasons =
    [ Keeper_meta_contract.Session_conflict
    ; Keeper_meta_contract.Other_detail "opaque free-text"
    ]
  in
  List.iter
    (fun reason ->
       let decision =
         policy_decision_exn (Some (provider_runtime_error_of_reason reason))
       in
       check string
         ("terminal reason -> pause_current_work ("
          ^ Keeper_meta_contract.runtime_exhaustion_summary reason ^ ")")
         "pause_current_work"
         (KFP.lifecycle_effect_to_label decision.lifecycle_effect);
       check string "reason label" "runtime_exhausted_terminal" decision.reason)
    terminal_reasons

let test_supervisor_policy_runtime_error_no_reason_falls_through () =
  (* A [Provider_runtime_error] with [reason = None] (non-exhaustion
     provider/runtime error) must not be classified as runtime-exhausted;
     it falls through to [None], preserving pre-refactor behavior. *)
  let r =
    Reg.Provider_runtime_error
      { code = "provider_error"
      ; detail = "boom"
      ; provider_id = None
      ; http_status = None
      ; runtime_id = None
      ; reason = None
      }
  in
  check bool "reason=None yields no runtime-exhausted decision" true
    (Sup.failure_reason_policy_decision_for_test (Some r) = None)

let test_supervisor_policy_provider_timeout_catch_all_retries () =
  let r =
    Reg.Provider_runtime_error
      { code = "provider_error_timeout:http_operation"
      ; detail =
          "Provider 'unknown' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
      ; provider_id = None
      ; http_status = None
      ; runtime_id = None
      ; reason = None
      }
  in
  let decision = policy_decision_exn (Some r) in
  check string "scope" "provider"
    (KFP.failure_scope_to_label decision.failure_scope);
  check string "lifecycle" "soft_fail_turn"
    (KFP.lifecycle_effect_to_label decision.lifecycle_effect);
  check string "operator action" "inspect_provider_stream"
    (KFP.operator_action_to_label decision.operator_action);
  check string "reason" "provider_timeout:http_operation" decision.reason

(* ── Pure tests: keep_last_n ────────────────────────────── *)

let test_keep_last_n_under_limit () =
  let result = Sup.keep_last_n 5 "a" ["b"; "c"] in
  check int "length 3" 3 (List.length result);
  check string "first is new item" "a" (List.hd result)

let test_keep_last_n_at_limit () =
  let result = Sup.keep_last_n 3 "a" ["b"; "c"] in
  check int "length 3" 3 (List.length result);
  check string "first is new item" "a" (List.hd result)

let test_keep_last_n_over_limit () =
  let result = Sup.keep_last_n 3 "a" ["b"; "c"; "d"] in
  check int "length capped at 3" 3 (List.length result);
  check string "first is new item" "a" (List.hd result);
  (* oldest item "d" should be dropped *)
  check bool "old item dropped" false (List.mem "d" result)

(* ── Registry-based tests (replacing removed supervisor Hashtbl queries) *)

let test_fiber_health_unknown () =
  Reg.clear ();
  let health = Reg.fiber_health_of ~base_path:"/tmp" "nonexistent-keeper" in
  check bool "unknown for unregistered"
    true (health = KT.Fiber_unknown)

let test_registry_count_initially_zero () =
  Reg.clear ();
  check int "no keepers initially" 0 (Reg.count_running ())

let test_crash_log_empty_for_unknown () =
  Reg.clear ();
  check int "empty crash log" 0
    (List.length (Reg.crash_log_of ~base_path:"/tmp" "nonexistent"))

let test_should_cleanup_dead_true () =
  Reg.clear ();
  let _entry = Reg.register ~base_path:"/tmp" "dead1"
      (let json = `Assoc [
        ("name", `String "dead1");
        ("agent_name", `String "agent-dead1");
        ("trace_id", `String "trace-dead1");
        ("goal", `String "goal");
        ("sandbox_profile", `String "local");
        ("network_mode", `String "inherit");
        ("tool_access", `List []);
      ] in
      match Keeper_meta_json_parse.meta_of_json json with
      | Ok meta -> meta
      | Error err -> fail err)
  in
  Reg.mark_dead ~base_path:"/tmp" "dead1" ~at:10.0;
  let entry = Option.get (Reg.get ~base_path:"/tmp" "dead1") in
  check bool "ttl exceeded" true
    (Sup.should_cleanup_dead ~now:4000.0 ~dead_ttl_sec:3600.0 entry)

let test_should_cleanup_dead_false_when_recent () =
  Reg.clear ();
  let _entry = Reg.register ~base_path:"/tmp" "dead2"
      (let json = `Assoc [
        ("name", `String "dead2");
        ("agent_name", `String "agent-dead2");
        ("trace_id", `String "trace-dead2");
        ("goal", `String "goal");
        ("sandbox_profile", `String "local");
        ("network_mode", `String "inherit");
        ("tool_access", `List []);
      ] in
      match Keeper_meta_json_parse.meta_of_json json with
      | Ok meta -> meta
      | Error err -> fail err)
  in
  Reg.mark_dead ~base_path:"/tmp" "dead2" ~at:100.0;
  let entry = Option.get (Reg.get ~base_path:"/tmp" "dead2") in
  check bool "ttl not exceeded" false
    (Sup.should_cleanup_dead ~now:200.0 ~dead_ttl_sec:3600.0 entry)

(* ── Property: backoff invariants ───────────────────────── *)

let test_backoff_monotonic_until_cap () =
  (* backoff(n) <= backoff(n+1) for all n until cap *)
  let cap = Sup.backoff_delay 20 in  (* at attempt 20, always at cap *)
  let rec check_mono i prev =
    if i > 20 then ()
    else begin
      let curr = Sup.backoff_delay i in
      check bool (Printf.sprintf "attempt %d >= prev" i)
        true (curr >= prev);
      check bool (Printf.sprintf "attempt %d <= cap" i)
        true (curr <= cap);
      check_mono (i + 1) curr
    end
  in
  check_mono 0 0.0

let test_backoff_never_negative () =
  for i = 0 to 30 do
    let d = Sup.backoff_delay i in
    check bool (Printf.sprintf "attempt %d >= 0" i) true (d >= 0.0)
  done

(* ── Property: keep_last_n invariants ──────────────────── *)

let test_keep_last_n_never_exceeds () =
  let n = 5 in
  let result = ref [] in
  for _i = 0 to 20 do
    result := Sup.keep_last_n n "x" !result
  done;
  check bool "length <= n" true (List.length !result <= n)

let test_done_signal_publishes_only_for_fresh_resolution () =
  check
    bool
    "fresh resolve publishes lifecycle"
    true
    (Sup.should_publish_lifecycle_for_done_signal Sup.Done_signal_resolved_now);
  check
    bool
    "already resolved does not publish lifecycle"
    false
    (Sup.should_publish_lifecycle_for_done_signal Sup.Done_signal_already_resolved);
  check
    bool
    "already seen does not publish lifecycle"
    false
    (Sup.should_publish_lifecycle_for_done_signal Sup.Done_signal_already_seen)

let test_done_signal_maps_registry_result () =
  check
    bool
    "registry fresh resolve publishes"
    true
    (Reg.Done_resolved { source = "test" }
     |> Sup.done_signal_of_registry_result
     |> Sup.should_publish_lifecycle_for_done_signal);
  check
    bool
    "registry already-resolved suppresses publish"
    false
    (Reg.Done_already_resolved { source = "test"; previous = `Stopped }
     |> Sup.done_signal_of_registry_result
     |> Sup.should_publish_lifecycle_for_done_signal)

(* ── Property: self-preservation subset ────────────────── *)

let bp = "/tmp/test-sp-prop"
let make_meta name =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-" ^ name));
    ("goal", `String "test");
    ("sandbox_profile", `String "local");
    ("network_mode", `String "inherit");
    ("tool_access", `List []);
  ] in
  match Keeper_meta_json_parse.meta_of_json json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

let create_started_task_for_meta config (meta : Keeper_meta_contract.keeper_meta) ~title =
  let created =
    match
      Masc.Workspace.add_task_with_result
        config
        ~title
        ~priority:1
        ~description:"test task"
    with
    | Ok created -> created
    | Error err -> fail (Masc.Workspace.add_task_error_to_string err)
  in
  (match
     Masc.Workspace.claim_task_r
       config
       ~agent_name:meta.agent_name
       ~task_id:created.task_id
       ()
   with
   | Ok _ -> ()
   | Error err -> fail (Masc_domain.masc_error_to_string err));
  (match
     Masc.Workspace.transition_task_r
       config
       ~agent_name:meta.agent_name
       ~task_id:created.task_id
       ~action:Masc_domain.Start
       ()
   with
   | Ok _ -> ()
   | Error err -> fail (Masc_domain.masc_error_to_string err));
  created

let task_status_for_id config task_id =
  Masc.Workspace.get_tasks_raw config
  |> List.find (fun (task : Masc_domain.task) -> String.equal task.id task_id)
  |> fun (task : Masc_domain.task) -> task.task_status

let noop_load_or_materialize_keeper_meta _ctx _name = Ok None

(* [pacing_enforced] defaults to [true] — the production runtime default
   (RFC-0313 W3, [config/runtime.toml] [pacing] mode = "enforce").  The
   legacy failure-driven pause tests pass [~pacing_enforced:false]
   explicitly: they pin the shadow kill-switch semantics until W4 deletes
   the pause arms and those tests with them. *)
let sweep_and_recover_no_materialize ?(pacing_enforced = true) ctx =
  Sup.sweep_and_recover
    ~load_or_materialize_keeper_meta:noop_load_or_materialize_keeper_meta
    ~pacing_enforced
    ctx

let test_pending_hitl_approval_keeper_names_filters_persisted_pending () =
  let base_dir = temp_dir () in
  let approval_ids = ref [] in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun id ->
          ignore
            (AQ.resolve
               ~id
               ~decision:(Agent_sdk.Hooks.Reject "test cleanup")))
        !approval_ids;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _workspace =
        Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name)
      in
      let blocked = make_meta "hitl-blocked" in
      let clear = make_meta "hitl-clear" in
      List.iter
        (fun meta ->
          match Keeper_meta_store.write_meta config meta with
          | Ok () -> ()
          | Error err -> fail err)
        [ blocked; clear ];
      let submit keeper_name =
        let id =
          AQ.submit_pending
            ~keeper_name
            ~tool_name:"keeper_continue_after_reconcile"
            ~input:(`Assoc [])
            ~risk_level:AQ.Critical
            ~base_path:config.base_path
            ~on_resolution:(fun _ -> ())
            ()
        in
        approval_ids := id :: !approval_ids
      in
      submit blocked.name;
      submit "not-persisted";
      check (list string) "only persisted pending keeper is surfaced"
        [ blocked.name ]
        (Sup.pending_hitl_approval_keeper_names config))

(* Sweep paths that resolve a keeper's runtime id reach
   [Keeper_meta_contract.runtime_id_of_meta], which falls back to
   [Runtime.get_default_runtime_id ()] for keepers without an explicit
   [[runtime.assignments]] entry.  That fallback fail-fasts until
   [Runtime.init_default] has run (RFC-0206 §2.1, no silent fallback).
   In a booted server [init_default] runs at startup
   (server_runtime_bootstrap.ml); a bare [dune exec] test binary must
   stand the default runtime up itself.  Mirrors the established pattern in
   test_keeper_lifecycle_registry_dispatch.ml. *)
let test_runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let ensure_test_runtime =
  let initialized = ref false in
  fun () ->
    if not !initialized then (
      let path = Filename.temp_file "keeper_supervisor_runtime_" ".toml" in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc test_runtime_toml);
      Fun.protect
        ~finally:(fun () ->
          try Sys.remove path with
          | Sys_error _ -> ())
        (fun () ->
          match Runtime.init_default ~config_path:path with
          | Ok () -> initialized := true
          | Error msg -> fail msg))

let test_persona_drift_check_uses_toml_persona_name () =
  with_config_dir @@ fun config_dir ->
  let keepers_dir = Filename.concat config_dir "keepers" in
  let executor_persona_dir =
    Filename.concat (Filename.concat config_dir "personas") "executor"
  in
  mkdir_p executor_persona_dir;
  write_file
    (Filename.concat executor_persona_dir "profile.json")
    {|{"name":"Executor","role":"execution"}|};
  write_file
    (Filename.concat keepers_dir "tech_glutton.toml")
    {|
[keeper]
name = "tech_glutton"
persona_name = "executor"
goal = "plan coding work"
|};
  match Sup.persona_name_for_drift_check (make_meta "tech_glutton") with
  | Ok persona_name ->
    check string "drift check honors TOML persona_name" "executor" persona_name
  | Error error ->
    fail (Keeper_types_profile.keeper_toml_load_error_to_string error)

let test_persona_drift_check_preserves_invalid_config () =
  with_config_dir @@ fun config_dir ->
  let keepers_dir = Filename.concat config_dir "keepers" in
  write_file
    (Filename.concat keepers_dir "invalid.toml")
    "[keeper\nname = \"invalid\"\n";
  match Sup.persona_name_for_drift_check (make_meta "invalid") with
  | Error _ -> ()
  | Ok persona_name ->
    fail
      (Printf.sprintf
         "invalid config must not fall back to persona identity %S"
         persona_name)

let test_persona_drift_path_points_to_profile_json () =
  with_config_dir @@ fun config_dir ->
  let expected =
    Filename.concat
      (Filename.concat (Filename.concat config_dir "personas") "executor")
      "profile.json"
  in
  check
    string
    "profile path"
    expected
    (Sup.persona_profile_path_for_drift_check
       ~base_path:(Filename.dirname (Filename.dirname config_dir))
       "executor")

let test_missing_persona_with_inline_toml_is_warn () =
  with_config_dir @@ fun config_dir ->
  let keepers_dir = Filename.concat config_dir "keepers" in
  write_file
    (Filename.concat keepers_dir "inline-only.toml")
    {|
[keeper]
name = "inline-only"
persona_name = "missing-profile"
goal = "inline keeper metadata is enough to run"
|};
  check
    bool
    "inline TOML missing profile is warn"
    true
    (match Sup.persona_drift_log_level_for_missing_profile
             (make_meta "inline-only")
     with
     | Sup.Persona_drift_warn -> true
     | Sup.Persona_drift_error -> false)

let test_missing_persona_without_profile_or_toml_is_error () =
  with_config_dir @@ fun _config_dir ->
  check
    bool
    "missing profile without TOML is error"
    true
    (match Sup.persona_drift_log_level_for_missing_profile
             (make_meta "missing-everywhere")
     with
     | Sup.Persona_drift_error -> true
     | Sup.Persona_drift_warn -> false)

let keeper_runtime_context env sw config : _ Keeper_types_profile.context =
  {
    config;
    agent_name = supervisor_agent_name;
    sw;
    clock = Eio.Stdenv.clock env;
    proc_mgr = Some (Eio.Stdenv.process_mgr env);
    net = Some (Eio.Stdenv.net env);
  }

let latest_log_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> entry.seq
  | [] -> -1

let test_declarative_boot_materializes_goal_from_instructions () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let name = "intent-only" in
  let instructions = "watch fleet safety and repair keeper bootstrap" in
  write_keeper_toml_without_goal config_dir ~name ~instructions;
  Eio.Switch.on_release sw (fun () ->
      Reg.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let ctx = keeper_runtime_context env sw config in
  Fun.protect
    ~finally:(fun () -> KR.stop_keepalive ~base_path:config.base_path name)
    (fun () ->
      match KR.load_or_materialize_boot_meta ctx name with
      | Error err -> fail err
      | Ok resolution ->
      check bool "materialized from declarative TOML" true resolution.materialized;
      check string "goal derived from instructions" instructions
        resolution.meta.goal;
      check bool "boot failure cleared" true
        (Option.is_none
           (KR.boot_meta_failure_for ~base_path:config.base_path ~name)))

let test_declarative_boot_records_goal_required_failure () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let name = "empty-intent" in
  write_empty_keeper_toml_without_goal config_dir ~name;
  Eio.Switch.on_release sw (fun () ->
      Reg.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let ctx = keeper_runtime_context env sw config in
  (match KR.load_or_materialize_boot_meta ctx name with
   | Ok _ -> fail "expected declarative keeper without any intent to fail"
   | Error err ->
       check bool "failure mentions goal" true
         (String_util.contains_substring err "goal is required"));
  match KR.boot_meta_failure_for ~base_path:config.base_path ~name with
  | None -> fail "expected boot meta failure to be recorded"
  | Some failure ->
      check string "failure keeper name" name failure.keeper_name;
      check string "recorded failure cause" "goal_required"
        (KR.boot_meta_failure_cause_label failure.cause);
      check bool "recorded failure keeps raw error" true
        (String_util.contains_substring failure.error "goal is required")

let test_declarative_boot_records_typed_invalid_config_failure () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let name = "invalid-config" in
  let keeper_path =
    Filename.concat (Filename.concat config_dir "keepers") (name ^ ".toml")
  in
  write_file keeper_path "[broken";
  Keeper_types_profile.invalidate_keeper_profile_defaults_cache name;
  Eio.Switch.on_release sw (fun () ->
      Reg.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let ctx = keeper_runtime_context env sw config in
  check bool "invalid configured keeper remains discoverable" true
    (List.mem name (Keeper_meta_store.configured_keeper_names config));
  check bool "invalid configured keeper is not executable" false
    (List.mem name (KR.bootable_keeper_names config));
  (match KR.load_or_materialize_boot_meta ctx name with
   | Ok _ -> fail "expected invalid keeper config to block materialization"
   | Error err ->
     check bool "operator-facing error retains path" true
       (String_util.contains_substring err keeper_path));
  match KR.boot_meta_failure_for ~base_path:config.base_path ~name with
  | None -> fail "expected invalid config boot failure to be recorded"
  | Some failure ->
    check string "generic typed config cause" "config_invalid"
      (KR.boot_meta_failure_cause_label failure.cause);
    (match failure.config_error with
     | None -> fail "expected typed config error on boot failure"
     | Some error ->
       check bool "parse kind retained" true
         (error.kind = Keeper_types_profile.Parse_error);
       check string "keeper path retained" keeper_path error.keeper_path;
       check string "failing path retained" keeper_path error.failing_path)

let test_reconcile_materializes_configured_keeper_without_meta () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let name = "hot-restored" in
  write_keeper_toml config_dir ~name;
  Eio.Switch.on_release sw (fun () ->
      Reg.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let ctx = keeper_runtime_context env sw config in
  let materialized = ref [] in
  let supervised = ref [] in
  let publish_lifecycle ~event:_ _name _detail () = () in
  let supervise_keepalive ~proactive_warmup_sec:_ _ctx
      (meta : Keeper_meta_contract.keeper_meta) =
    supervised := meta.name :: !supervised
  in
  let load_or_materialize_keeper_meta _ctx requested =
    materialized := requested :: !materialized;
    Ok (Some (make_meta requested))
  in
  KSR.reconcile_keepalive_keepers
    ~publish_lifecycle
    ~supervise_keepalive
    ~load_or_materialize_keeper_meta
    ctx;
  check (list string) "materialized missing meta" [ name ]
    (List.rev !materialized);
  check (list string) "supervised materialized keeper" [ name ]
    (List.rev !supervised)

let test_reconcile_does_not_double_start_materialized_keeper () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let name = "hot-registered" in
  write_keeper_toml config_dir ~name;
  Eio.Switch.on_release sw (fun () ->
      Reg.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let ctx = keeper_runtime_context env sw config in
  let materialized = ref [] in
  let supervised = ref [] in
  let publish_lifecycle ~event:_ _name _detail () = () in
  let supervise_keepalive ~proactive_warmup_sec:_ _ctx
      (meta : Keeper_meta_contract.keeper_meta) =
    supervised := meta.name :: !supervised
  in
  let load_or_materialize_keeper_meta _ctx requested =
    materialized := requested :: !materialized;
    let meta = make_meta requested in
    let _entry = Reg.register_offline ~base_path:config.base_path requested meta in
    Ok (Some meta)
  in
  KSR.reconcile_keepalive_keepers
    ~publish_lifecycle
    ~supervise_keepalive
    ~load_or_materialize_keeper_meta
    ctx;
  check (list string) "materialized missing meta" [ name ]
    (List.rev !materialized);
  check (list string) "already registered keeper not supervised" []
    (List.rev !supervised);
  check bool "materialized keeper registered" true
    (Reg.is_registered ~base_path:config.base_path name)

let test_reconcile_repairs_persisted_no_progress_paused_task_owner () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let name = "paused-no-progress-owner" in
  write_keeper_toml config_dir ~name;
  Eio.Switch.on_release sw (fun () ->
      Reg.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let ctx = keeper_runtime_context env sw config in
  let base_meta = make_meta name in
  let created =
    create_started_task_for_meta
      config
      base_meta
      ~title:"persisted no-progress owner release"
  in
  let task_id =
    match Keeper_id.Task_id.of_string created.task_id with
    | Ok task_id -> task_id
    | Error err -> fail err
  in
  let meta =
    {
      base_meta with
      paused = true;
      current_task_id = Some task_id;
      runtime =
        {
          base_meta.runtime with
          last_blocker =
            Some
              (Keeper_meta_contract.blocker_info_of_class
                 ~detail:"no_progress loop detected"
                 Keeper_meta_contract.No_progress_loop);
        };
    }
  in
  (match Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error err -> fail err);
  let supervised = ref [] in
  let publish_lifecycle ~event:_ _name _detail () = () in
  let supervise_keepalive ~proactive_warmup_sec:_ _ctx
      (meta : Keeper_meta_contract.keeper_meta) =
    supervised := meta.name :: !supervised
  in
  KSR.reconcile_keepalive_keepers
    ~publish_lifecycle
    ~supervise_keepalive
    ~load_or_materialize_keeper_meta:noop_load_or_materialize_keeper_meta
    ctx;
  check (list string) "paused keeper is not supervised" [] (List.rev !supervised);
  (match task_status_for_id config created.task_id with
   | Masc_domain.Todo -> ()
   | status ->
     fail
       (Printf.sprintf
          "expected paused owner task to be released, got %s"
          (Masc_domain.task_status_to_string status)));
  match Keeper_meta_store.read_meta config name with
  | Ok (Some persisted) ->
    check bool "keeper remains paused" true persisted.paused;
    check (option string) "stale current_task_id cleared" None
      (Option.map Keeper_id.Task_id.to_string persisted.current_task_id)
  | Ok None -> fail "expected persisted keeper meta"
  | Error err -> fail err

let test_reconcile_keeps_manual_paused_task_owner () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let name = "manual-paused-owner" in
  write_keeper_toml config_dir ~name;
  Eio.Switch.on_release sw (fun () ->
      Reg.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let ctx = keeper_runtime_context env sw config in
  let base_meta = make_meta name in
  let created =
    create_started_task_for_meta config base_meta ~title:"manual paused owner"
  in
  let task_id =
    match Keeper_id.Task_id.of_string created.task_id with
    | Ok task_id -> task_id
    | Error err -> fail err
  in
  let meta = { base_meta with paused = true; current_task_id = Some task_id } in
  (match Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error err -> fail err);
  let publish_lifecycle ~event:_ _name _detail () = () in
  let supervise_keepalive ~proactive_warmup_sec:_ _ctx _meta = () in
  KSR.reconcile_keepalive_keepers
    ~publish_lifecycle
    ~supervise_keepalive
    ~load_or_materialize_keeper_meta:noop_load_or_materialize_keeper_meta
    ctx;
  (match task_status_for_id config created.task_id with
   | Masc_domain.InProgress { assignee; _ } ->
     check string "manual pause keeps active owner" base_meta.agent_name assignee
   | status ->
     fail
       (Printf.sprintf
          "expected manual paused owner task to stay in_progress, got %s"
          (Masc_domain.task_status_to_string status)));
  match Keeper_meta_store.read_meta config name with
  | Ok (Some persisted) ->
    check bool "keeper remains paused" true persisted.paused;
    check (option string) "current_task_id preserved"
      (Some created.task_id)
      (Option.map Keeper_id.Task_id.to_string persisted.current_task_id)
  | Ok None -> fail "expected persisted keeper meta"
  | Error err -> fail err

let test_reconcile_materialize_failure_continues_with_metric () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let failing = "a-missing-meta" in
  let healthy = "b-hot-restored" in
  write_keeper_toml config_dir ~name:failing;
  write_keeper_toml config_dir ~name:healthy;
  Eio.Switch.on_release sw (fun () ->
      Reg.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let ctx = keeper_runtime_context env sw config in
  let supervised = ref [] in
  let metric = Keeper_metrics.(to_string KeeperMaterializationFailures) in
  let before = Masc.Otel_metric_store.metric_total metric in
  let publish_lifecycle ~event:_ _name _detail () = () in
  let supervise_keepalive ~proactive_warmup_sec:_ _ctx
      (meta : Keeper_meta_contract.keeper_meta) =
    supervised := meta.name :: !supervised
  in
  let load_or_materialize_keeper_meta _ctx requested =
    if String.equal requested failing
    then Error "fixture materialize failure"
    else Ok (Some (make_meta requested))
  in
  KSR.reconcile_keepalive_keepers
    ~publish_lifecycle
    ~supervise_keepalive
    ~load_or_materialize_keeper_meta
    ctx;
  check (list string) "later keeper still supervised" [ healthy ]
    (List.rev !supervised);
  check (float 0.001) "materialize failure metric increments" (before +. 1.)
    (Masc.Otel_metric_store.metric_total metric)

let test_reconcile_supervise_exception_continues () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let failing = "a-supervise-raises" in
  let healthy = "b-supervised" in
  write_keeper_toml config_dir ~name:failing;
  write_keeper_toml config_dir ~name:healthy;
  Eio.Switch.on_release sw (fun () ->
      Reg.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let ctx = keeper_runtime_context env sw config in
  let supervised = ref [] in
  let metric = Keeper_metrics.(to_string ReconcileFailures) in
  let before = Masc.Otel_metric_store.metric_total metric in
  let publish_lifecycle ~event:_ _name _detail () = () in
  let supervise_keepalive ~proactive_warmup_sec:_ _ctx
      (meta : Keeper_meta_contract.keeper_meta) =
    if String.equal meta.name failing
    then raise (Failure "fixture supervise failure")
    else supervised := meta.name :: !supervised
  in
  let load_or_materialize_keeper_meta _ctx requested =
    Ok (Some (make_meta requested))
  in
  KSR.reconcile_keepalive_keepers
    ~publish_lifecycle
    ~supervise_keepalive
    ~load_or_materialize_keeper_meta
    ctx;
  check (list string) "later keeper still supervised" [ healthy ]
    (List.rev !supervised);
  check (float 0.001) "reconcile failure metric increments" (before +. 1.)
    (Masc.Otel_metric_store.metric_total metric)

let registered_entries names =
  Reg.clear ();
  List.map
    (fun name -> Reg.register ~base_path:bp name (make_meta name))
    names

let test_supervision_cohorts_64_keepers_8x8 () =
  let names =
    List.init 64 (fun i -> Printf.sprintf "keeper-%02d" i)
  in
  let entries = registered_entries (List.rev names) in
  let cohorts = Sup.supervision_cohorts entries in
  check int "cohort count" 8 (List.length cohorts);
  List.iteri
    (fun i (cohort : Sup.supervision_cohort) ->
      check int "cohort id" i cohort.cohort_id;
      check int "cohort size" Sup.supervision_cohort_size
        (List.length cohort.keepers))
    cohorts;
  let flattened =
    cohorts
    |> List.concat_map (fun (cohort : Sup.supervision_cohort) -> cohort.keepers)
    |> List.map (fun (entry : Reg.registry_entry) -> entry.name)
  in
  check (list string) "all keepers exactly once in stable order"
    names flattened

let test_supervision_cohorts_custom_size_and_floor () =
  let names = [ "delta"; "alpha"; "echo"; "bravo"; "charlie" ] in
  let entries = registered_entries names in
  let sizes =
    Sup.supervision_cohorts ~cohort_size:2 entries
    |> List.map (fun (cohort : Sup.supervision_cohort) ->
           List.length cohort.keepers)
  in
  check (list int) "custom cohort sizes" [ 2; 2; 1 ] sizes;
  let floored_sizes =
    Sup.supervision_cohorts ~cohort_size:0 entries
    |> List.map (fun (cohort : Sup.supervision_cohort) ->
           List.length cohort.keepers)
  in
  check (list int) "non-positive cohort size coerces to one"
    [ 1; 1; 1; 1; 1 ] floored_sizes

let test_supervision_cohorts_large_custom_size_yields_between_only () =
  let names = List.init 192 (fun i -> Printf.sprintf "keeper-%03d" i) in
  let entries = registered_entries names in
  let cohorts = Sup.supervision_cohorts ~cohort_size:64 entries in
  check int "cohort count" 3 (List.length cohorts);
  let visited = ref [] in
  let yields = ref 0 in
  Sup.iter_supervision_cohorts
    ~yield_between:(fun () -> incr yields)
    cohorts
    ~f:(fun (cohort : Sup.supervision_cohort) ->
      visited := cohort.cohort_id :: !visited);
  check (list int) "visited cohorts" [ 0; 1; 2 ] (List.rev !visited);
  check int "yield between cohorts only" 2 !yields

let test_fresh_supervision_cohort_keepers_rereads_registry () =
  let entries = registered_entries [ "alpha"; "bravo" ] in
  let cohort =
    match Sup.supervision_cohorts ~cohort_size:2 entries with
    | [ cohort ] -> cohort
    | _ -> fail "expected one cohort"
  in
  Reg.unregister ~base_path:bp "alpha";
  Reg.unregister ~base_path:bp "bravo";
  let _entry = Reg.register_offline ~base_path:bp "bravo" (make_meta "bravo") in
  let fresh = Sup.fresh_supervision_cohort_keepers ~base_path:bp cohort in
  check (list string) "removed entries omitted"
    [ "bravo" ]
    (List.map (fun (entry : Reg.registry_entry) -> entry.name) fresh);
  match fresh with
  | [ entry ] ->
      check string "entry was re-read from registry" "offline"
        (KSM.phase_to_string entry.phase)
  | _ -> fail "expected one fresh entry"

let test_restart_launch_noop_scope_restores_nested_state () =
  let previous = Sup.restart_launch_noop_enabled_for_test () in
  Fun.protect
    ~finally:(fun () -> Sup.set_restart_launch_noop_for_test previous)
    (fun () ->
      Sup.set_restart_launch_noop_for_test false;
      Sup.with_restart_launch_noop_for_test (fun () ->
          check bool "outer enables noop" true
            (Sup.restart_launch_noop_enabled_for_test ());
          Sup.with_restart_launch_noop_for_test (fun () ->
              check bool "inner keeps noop" true
                (Sup.restart_launch_noop_enabled_for_test ()));
          check bool "outer remains enabled" true
            (Sup.restart_launch_noop_enabled_for_test ()));
      check bool "restored false" false
        (Sup.restart_launch_noop_enabled_for_test ());
      Sup.set_restart_launch_noop_for_test true;
      Sup.with_restart_launch_noop_for_test (fun () ->
          check bool "preserves prior true in scope" true
            (Sup.restart_launch_noop_enabled_for_test ()));
      check bool "restored prior true" true
        (Sup.restart_launch_noop_enabled_for_test ()))

let test_spawn_admission_denial_does_not_register_or_fork () =
  with_restart_launch_noop @@ fun () ->
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Eio.Switch.on_release sw (fun () ->
    FD.reset_for_tests ();
    Reg.clear ();
    Masc.Keeper_runtime.reset_test_state base_dir;
    cleanup_dir base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let name = "spawn-denied-no-fork" in
  let meta = make_meta name in
  (match Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error err -> fail err);
  let ctx : _ Keeper_types_profile.context =
    {
      config;
      agent_name = supervisor_agent_name;
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = Some (Eio.Stdenv.process_mgr env);
      net = Some (Eio.Stdenv.net env);
    }
  in
  let denial_metric = Keeper_metrics.(to_string SpawnSlotDenied) in
  let denial_count surface =
    Masc.Otel_metric_store.metric_value_or_zero
      denial_metric
      ~labels:
        [
          ("keeper", name);
          ("surface", surface);
          ("reason", "fd_pressure_active");
        ]
      ()
  in
  let fork_total () =
    Masc.Otel_metric_store.metric_total
      Keeper_metrics.(to_string DomainPoolFork)
  in
  FD.note ~site:"test_spawn_admission_no_fork"
    ~detail:"Too many open files in system"
    ();
  check bool "fd pressure active" true (FD.active ());
  let fork_before = fork_total () in
  let keepalive_denials_before = denial_count "keepalive" in
  ignore (KA.start_keepalive ctx meta : KA.start_keepalive_outcome);
  check bool "keepalive denial does not register keeper" false
    (Reg.is_registered ~base_path:config.base_path name);
  check (float 0.001) "keepalive denial metric increments"
    (keepalive_denials_before +. 1.0)
    (denial_count "keepalive");
  let supervisor_denials_before = denial_count "supervisor" in
  Sup.supervise_keepalive ~proactive_warmup_sec:0 ctx meta;
  check bool "supervisor denial does not register keeper" false
    (Reg.is_registered ~base_path:config.base_path name);
  check (float 0.001) "supervisor denial metric increments"
    (supervisor_denials_before +. 1.0)
    (denial_count "supervisor");
  check (float 0.001) "spawn denial does not fork heartbeat" fork_before (fork_total ())

let test_active_supervision_keeper_count_uses_current_entries () =
  let entries = registered_entries [ "alpha"; "bravo" ] in
  check int "initial active count" 2
    (Sup.active_supervision_keeper_count entries);
  Reg.unregister ~base_path:bp "bravo";
  let _entry = Reg.register_offline ~base_path:bp "bravo" (make_meta "bravo") in
  let fresh_entries = Reg.all ~base_path:bp () in
  check int "fresh active count excludes offline" 1
    (Sup.active_supervision_keeper_count fresh_entries)

let test_self_preservation_subset () =
  Eio_main.run @@ fun _env ->
  Reg.clear ();
  let names = ["a"; "b"; "c"; "d"; "e"] in
  let entries = List.map (fun name ->
    let _reg = Reg.register ~base_path:bp name (make_meta name) in
    ignore (Reg.dispatch_event ~base_path:bp name
      (Keeper_state_machine.Fiber_terminated { outcome = "test"; provider_id = None; http_status = None }));
    Reg.set_failure_reason ~base_path:bp name
      (Some (Reg.Heartbeat_consecutive_failures 3));
    match Reg.get ~base_path:bp name with
    | Some e -> (e, "crash") | None -> fail name
  ) names in
  let result = Sup.apply_self_preservation ~keepers_dir:"/tmp/test-keepers" ~total_keepers:10 entries in
  let result_names = List.map (fun ((e : Reg.registry_entry), _) -> e.name) result in
  let input_names = List.map (fun ((e : Reg.registry_entry), _) -> e.name) entries in
  List.iter (fun rn ->
    check bool (Printf.sprintf "%s in input" rn) true (List.mem rn input_names)
  ) result_names

let test_self_preservation_empty_input () =
  let result = Sup.apply_self_preservation ~keepers_dir:"/tmp/test-keepers" ~total_keepers:5 [] in
  check int "empty in = empty out" 0 (List.length result)

let stale_entries names =
  List.map
    (fun name ->
      ignore (Reg.register ~base_path:bp name (make_meta name));
      Reg.set_failure_reason ~base_path:bp name
        (Some
           (Reg.Stale_turn_timeout
              (Reg.Idle_turn { stall_seconds = 99_000.0 })));
      match Reg.get ~base_path:bp name with
      | Some e -> (e, "stale_turn_timeout")
      | None -> fail name)
    names

let test_self_preservation_allows_bounded_partial_stale_recovery () =
  Reg.clear ();
  Sup.reset_self_preservation_escape_state_for_test ();
  let names = [ "a"; "b"; "c"; "d"; "e"; "f" ] in
  let entries = stale_entries names in
  let result =
    Sup.apply_self_preservation ~keepers_dir:"/tmp/test-keepers"
      ~total_keepers:17 entries
  in
  check int "partial stale recovery cohort allowed through"
    (List.length entries) (List.length result);
  Sup.reset_self_preservation_escape_state_for_test ();
  Reg.clear ()

let test_self_preservation_allows_mixed_partial_stale_recovery () =
  Reg.clear ();
  Sup.reset_self_preservation_escape_state_for_test ();
  let stale = stale_entries [ "a"; "b"; "c"; "d"; "e"; "f" ] in
  let crash =
    let name = "non-stale-crash" in
    ignore (Reg.register ~base_path:bp name (make_meta name));
    Reg.set_failure_reason ~base_path:bp name
      (Some (Reg.Heartbeat_consecutive_failures 3));
    match Reg.get ~base_path:bp name with
    | Some e -> [ e, "crash" ]
    | None -> fail name
  in
  let entries = stale @ crash in
  let result =
    Sup.apply_self_preservation ~keepers_dir:"/tmp/test-keepers"
      ~total_keepers:17 entries
  in
  check int "mixed partial stale recovery keeps full restart set"
    (List.length entries) (List.length result);
  Sup.reset_self_preservation_escape_state_for_test ();
  Reg.clear ()

let test_self_preservation_suppresses_large_partial_stale_recovery () =
  Reg.clear ();
  Sup.reset_self_preservation_escape_state_for_test ();
  let entries =
    stale_entries
      [ "a"; "b"; "c"; "d"; "e"; "f"; "g"; "h"; "i" ]
  in
  let result =
    Sup.apply_self_preservation ~keepers_dir:"/tmp/test-keepers"
      ~total_keepers:17 entries
  in
  check int "large partial stale cohort suppressed" 0 (List.length result);
  Sup.reset_self_preservation_escape_state_for_test ();
  Reg.clear ()

let test_self_preservation_suppresses_universal_stale_recovery () =
  Reg.clear ();
  Sup.reset_self_preservation_escape_state_for_test ();
  let entries =
    stale_entries
      [ "a"; "b"; "c"; "d"; "e"; "f"; "g"; "h"; "i"; "j"; "k"; "l";
        "m"; "n"; "o"; "p"; "q" ]
  in
  let result =
    Sup.apply_self_preservation ~keepers_dir:"/tmp/test-keepers"
      ~total_keepers:17 entries
  in
  check int "universal stale cohort suppressed" 0 (List.length result);
  Sup.reset_self_preservation_escape_state_for_test ();
  Reg.clear ()

let test_self_preservation_partial_suppression_warn_cadence () =
  let should_warn streak =
    KSP.For_testing.should_warn_partial_suppression_streak ~streak
  in
  check bool "first partial suppression warns" true (should_warn 1);
  check bool "middle partial suppression is debug" false (should_warn 2);
  check bool "pre-probe partial suppression warns" true (should_warn 9);
  check bool "probe path logs separately" false (should_warn 10)

(* ── Runtime override: fiber_health_of ─────────────────── *)

let test_fiber_health_respects_max_restarts_override () =
  Reg.clear ();
  let name = "override-test-keeper" in
  let meta = make_meta name in
  let reg = Reg.register ~base_path:bp name meta in
  (* Simulate crash: resolve done_p as Crashed *)
  resolve_done_for_test reg (`Crashed "test crash");
  (* Set restart_count to 3 *)
  Reg.restore_supervisor_state ~base_path:bp name
    ~restart_count:3 ~last_restart_ts:0.0 ~crash_log:[];
  (* Default max_restarts is 5 (from env_config).
     With restart_count=3 and done_p=Crashed, health = Fiber_zombie *)
  let health_before = Reg.fiber_health_of ~base_path:bp name in
  check bool "zombie at 3/5 restarts (restartable)"
    true (health_before = KT.Fiber_zombie);
  (* Override max_restarts to 2 — now restart_count 3 >= 2 = dead *)
  (match Masc.Runtime_params.set
    Masc.Governance_registry.keeper_supervisor_max_restarts 2 with
  | Ok () -> ()
  | Error msg -> fail msg);
  let health_after = Reg.fiber_health_of ~base_path:bp name in
  check bool "dead at 3/2 restarts (overridden)"
    true (health_after = KT.Fiber_dead);
  (* Restore default *)
  Masc.Runtime_params.clear
    Masc.Governance_registry.keeper_supervisor_max_restarts;
  Reg.clear ()

let test_sweep_restores_reconcile_gate_for_paused_keeper () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_keepalive.stop_keepalive ~base_path:base_dir "paused-reconcile";
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _workspace = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let base = make_meta "paused-reconcile" in
      let meta =
        {
          base with
          paused = true;
          autoboot_enabled = true;
          runtime =
            {
              base.runtime with
              last_blocker =
                Some
                  (Keeper_meta_contract.blocker_info_of_class
                     ~detail:"turn outcome ambiguous after committed mutating tool call(s): [keeper_board_post]; retry disabled to avoid duplicate mutation; original_error=Completion contract [completion_contract] violated"
                     Keeper_meta_contract.Ambiguous_post_commit_timeout);
            };
        }
      in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      let pending_before = AQ.pending_count () in
      sweep_and_recover_no_materialize ctx;
      check bool "paused keeper has pending approval" true
        (AQ.has_pending_for_keeper ~keeper_name:meta.name);
      check int "approval count incremented"
        (pending_before + 1) (AQ.pending_count ());
      let approval_id =
        match AQ.list_pending_json () with
        | `List entries ->
            entries
            |> List.find_map (function
                 | `Assoc fields ->
                     let row = `Assoc fields in
                     if Yojson.Safe.Util.(row |> member "keeper_name" |> to_string_option)
                        = Some meta.name
                     then Yojson.Safe.Util.(row |> member "id" |> to_string_option)
                     else None
                 | _ -> None)
            |> Option.value ~default:""
        | _ -> ""
      in
      check bool "approval id present" true (approval_id <> "");
      (match AQ.resolve ~id:approval_id ~decision:Agent_sdk.Hooks.Approve with
       | Ok () -> ()
       | Error err -> fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
      let resumed_meta =
        match Keeper_meta_store.read_meta config meta.name with
        | Ok (Some value) -> value
        | Ok None -> fail "expected resumed keeper meta"
        | Error err -> fail err
      in
      check bool "paused cleared after approval" false resumed_meta.paused;
      check bool "blocker cleared after approval" true
        (Option.is_none resumed_meta.runtime.last_blocker);
      check bool "keeper registered after approval" true
        (Reg.is_registered ~base_path:config.base_path meta.name))

let test_sweep_reports_pending_hitl_approval () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let name = "hitl-visible-sweep" in
  let approval_id = ref None in
  Fun.protect
    ~finally:(fun () ->
      Option.iter
        (fun id ->
           ignore
             (AQ.resolve
                ~id
                ~decision:(Agent_sdk.Hooks.Reject "test cleanup")))
        !approval_id;
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      Log.set_level Log.Info;
      let config = Masc.Workspace.default_config base_dir in
      let _workspace = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let callback_result = ref None in
      let id =
        AQ.submit_pending
          ~keeper_name:name
          ~tool_name:"keeper_continue_after_partial_commit"
          ~input:(`Assoc [ ("kind", `String "visibility_probe") ])
          ~risk_level:AQ.Critical
          ~base_path:config.base_path
          ~on_resolution:(fun decision -> callback_result := Some decision)
          ()
      in
      approval_id := Some id;
      let baseline = latest_log_seq () in
      let ctx = keeper_runtime_context env sw config in
      sweep_and_recover_no_materialize ctx;
      let expected =
        Printf.sprintf
          "keeper:%s has 1 nonblocking HITL approval(s); chat lane remains \
           available"
          name
      in
      let visibility_seen =
        Log.Ring.recent
          ~limit:50
          ~module_filter:"Keeper"
          ~min_level:(Log.level_to_int Log.Info)
          ~since_seq:baseline
          ()
        |> List.exists (fun (entry : Log.Ring.entry) ->
             String.equal entry.message expected)
      in
      check bool "pending HITL approval visibility emitted" true visibility_seen;
      check bool "approval remains pending after visibility sweep" true
        (AQ.has_pending_for_keeper ~keeper_name:name);
      (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
       | Ok () -> approval_id := None
       | Error err -> fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
      match !callback_result with
      | Some Agent_sdk.Hooks.Approve -> ()
      | Some decision ->
          fail
            ("expected approve callback, got "
             ^ AQ.approval_decision_to_string decision)
      | None -> fail "expected approval callback")

let test_restart_path_emits_attempt_and_started_outcome_metrics () =
  with_restart_launch_noop @@ fun () ->
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_config_dir @@ fun config_dir ->
  let base_dir = temp_dir () in
  let name = "restart-metric-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_keepalive.stop_keepalive ~base_path:base_dir name;
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      write_keeper_toml config_dir ~name;
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "ordinary crash");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      let attempt_labels = [ ("keeper", name) ] in
      let outcome_labels = [ ("keeper", name); ("outcome", "started") ] in
      let attempts_before =
        Masc.Otel_metric_store.metric_value_or_zero
          Keeper_metrics.(to_string RestartAttempts)
          ~labels:attempt_labels ()
      in
      let outcomes_before =
        Masc.Otel_metric_store.metric_value_or_zero
          Keeper_metrics.(to_string RestartOutcomes)
          ~labels:outcome_labels ()
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      check (float 0.001) "restart attempt recorded after lifecycle admission"
        (attempts_before +. 1.0)
        (Masc.Otel_metric_store.metric_value_or_zero
           Keeper_metrics.(to_string RestartAttempts)
           ~labels:attempt_labels ());
      check (float 0.001) "restart started outcome metric incremented"
        (outcomes_before +. 1.0)
        (Masc.Otel_metric_store.metric_value_or_zero
           Keeper_metrics.(to_string RestartOutcomes)
           ~labels:outcome_labels ());
      match Reg.get ~base_path:config.base_path name with
      | None -> fail "expected restarted keeper in registry"
      | Some entry ->
          check int "restart count restored to attempt" 1 entry.restart_count)

let test_restart_path_emits_meta_unavailable_outcome_metric () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let name = "restart-missing-meta-metric-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let meta = make_meta name in
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "ordinary crash");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      let attempt_labels = [ ("keeper", name) ] in
      let outcome_labels =
        [ ("keeper", name); ("outcome", "meta_unavailable") ]
      in
      let attempts_before =
        Masc.Otel_metric_store.metric_value_or_zero
          Keeper_metrics.(to_string RestartAttempts)
          ~labels:attempt_labels ()
      in
      let outcomes_before =
        Masc.Otel_metric_store.metric_value_or_zero
          Keeper_metrics.(to_string RestartOutcomes)
          ~labels:outcome_labels ()
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      check (float 0.001) "restart attempt not recorded without admission meta"
        attempts_before
        (Masc.Otel_metric_store.metric_value_or_zero
           Keeper_metrics.(to_string RestartAttempts)
           ~labels:attempt_labels ());
      check (float 0.001) "missing-meta outcome metric incremented"
        (outcomes_before +. 1.0)
        (Masc.Otel_metric_store.metric_value_or_zero
           Keeper_metrics.(to_string RestartOutcomes)
           ~labels:outcome_labels ());
      check bool "keeper unregistered after missing meta" false
        (Reg.is_registered ~base_path:config.base_path name))

let test_restart_denies_persisted_dead_tombstone () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_config_dir @@ fun config_dir ->
  let base_dir = temp_dir () in
  let name = "restart-dead-tombstone-admission" in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg =
        Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name)
      in
      write_keeper_toml config_dir ~name;
      let active_meta = make_meta name in
      let dead_meta =
        { active_meta with
          paused = true
        ; latched_reason = Some Keeper_latched_reason.Dead_tombstone
        }
      in
      (match Keeper_meta_store.write_meta config dead_meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name active_meta in
      resolve_done_for_test reg (`Crashed "crash before terminal persist");
      Reg.restore_supervisor_state
        ~base_path:config.base_path
        name
        ~restart_count:0
        ~last_restart_ts:0.0
        ~crash_log:[];
      let attempt_labels = [ "keeper", name ] in
      let denied_labels = [ "keeper", name; "outcome", "lifecycle_denied" ] in
      let attempts_before =
        Masc.Otel_metric_store.metric_value_or_zero
          Keeper_metrics.(to_string RestartAttempts)
          ~labels:attempt_labels
          ()
      in
      let denied_before =
        Masc.Otel_metric_store.metric_value_or_zero
          Keeper_metrics.(to_string RestartOutcomes)
          ~labels:denied_labels
          ()
      in
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = supervisor_agent_name
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = Some (Eio.Stdenv.net env)
        }
      in
      sweep_and_recover_no_materialize ctx;
      check (float 0.001) "terminal lane consumes no restart attempt"
        attempts_before
        (Masc.Otel_metric_store.metric_value_or_zero
           Keeper_metrics.(to_string RestartAttempts)
           ~labels:attempt_labels
           ());
      check (float 0.001) "typed lifecycle denial is observed"
        (denied_before +. 1.0)
        (Masc.Otel_metric_store.metric_value_or_zero
           Keeper_metrics.(to_string RestartOutcomes)
           ~labels:denied_labels
           ());
      match Reg.get ~base_path:config.base_path name with
      | None -> fail "terminal registry entry unexpectedly disappeared"
      | Some entry ->
        check int "restart count unchanged" 0 entry.restart_count;
        check bool "terminal registry phase is Dead" true
          (entry.phase = Keeper_state_machine.Dead);
        check bool "persisted tombstone meta becomes registry authority" true
          (match entry.meta.latched_reason with
           | Some Keeper_latched_reason.Dead_tombstone -> true
           | Some _ | None -> false);
        check bool "terminal transition records dead timestamp" true
          (Option.is_some entry.dead_since_ts))

(* ── Dead-state loud alert (PR-C) ──────────────────────── *)

(* Reproduces the 2026-04-25 incident pattern: 8 keepers crashed silently
   after the supervisor exhausted max_restarts. The ERROR log + Otel_metric_store
   counter + structured OAS event emitted from sweep_and_recover give
   operators the signal that was missing. *)
let test_max_restarts_exhaustion_emits_dead_alert () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "dead-alert-keeper" in
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      (* Drive the entry to Crashed with restart_count already at the
         default budget (5) so sweep takes the Dead branch on the first
         pass, not the restart branch. *)
      resolve_done_for_test reg (`Crashed "synthetic exhaustion");
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Heartbeat_consecutive_failures 9));
      let max_restarts =
        Masc.Runtime_params.get
          Masc.Governance_registry.keeper_supervisor_max_restarts
      in
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:max_restarts ~last_restart_ts:0.0 ~crash_log:[];
      let baseline =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string DeadTotal)
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      let after =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string DeadTotal)
      in
      check (float 0.001) "metric_keeper_dead_total incremented by 1"
        (baseline +. 1.0) after;
      (* Phase advanced to Dead. *)
      let phase =
        Reg.get_phase ~base_path:config.base_path name
        |> Option.value ~default:Keeper_state_machine.Running
      in
      check bool "keeper phase advanced to Dead"
        true (phase = Keeper_state_machine.Dead))

let test_max_restarts_exhaustion_releases_owned_task () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "dead-task-owner" in
      let base_meta = make_meta name in
      let created =
        match
          Masc.Workspace.add_task_with_result
            config
            ~title:"dead owner release regression"
            ~priority:1
            ~description:"task must be released when keeper exhausts restart budget"
        with
        | Ok created -> created
        | Error err -> fail (Masc.Workspace.add_task_error_to_string err)
      in
      (match
         Masc.Workspace.claim_task_r
           config
           ~agent_name:base_meta.agent_name
           ~task_id:created.task_id
           ()
       with
       | Ok _ -> ()
       | Error err -> fail (Masc_domain.masc_error_to_string err));
      (match
         Masc.Workspace.transition_task_r
           config
           ~agent_name:base_meta.agent_name
           ~task_id:created.task_id
           ~action:Masc_domain.Start
           ()
       with
       | Ok _ -> ()
       | Error err -> fail (Masc_domain.masc_error_to_string err));
      let task_id =
        match Keeper_id.Task_id.of_string created.task_id with
        | Ok task_id -> task_id
        | Error err -> fail err
      in
      let meta = { base_meta with current_task_id = Some task_id } in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "synthetic exhaustion");
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Heartbeat_consecutive_failures 9));
      let max_restarts =
        Masc.Runtime_params.get
          Masc.Governance_registry.keeper_supervisor_max_restarts
      in
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:max_restarts ~last_restart_ts:0.0 ~crash_log:[];
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      let task =
        Masc.Workspace.get_tasks_raw config
        |> List.find (fun (task : Masc_domain.task) ->
          String.equal task.id created.task_id)
      in
      (match task.task_status with
       | Masc_domain.Todo -> ()
       | status ->
         fail
           (Printf.sprintf
              "expected released task to be todo, got %s"
              (Masc_domain.task_status_to_string status)));
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some persisted) ->
         check (option string) "dead keeper current_task_id cleared" None
           (Option.map Keeper_id.Task_id.to_string persisted.current_task_id)
       | Ok None -> fail "expected persisted keeper meta"
       | Error err -> fail err))

let test_max_restarts_exhaustion_preserves_current_task_when_owned_task_query_fails () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "dead-task-owner-discovery-fails" in
      let base_meta = make_meta name in
      let created =
        match
          Masc.Workspace.add_task_with_result
            config
            ~title:"dead owner discovery failure regression"
            ~priority:1
            ~description:"current_task_id must survive backlog query failures"
        with
        | Ok created -> created
        | Error err -> fail (Masc.Workspace.add_task_error_to_string err)
      in
      (match
         Masc.Workspace.claim_task_r
           config
           ~agent_name:base_meta.agent_name
           ~task_id:created.task_id
           ()
       with
       | Ok _ -> ()
       | Error err -> fail (Masc_domain.masc_error_to_string err));
      (match
         Masc.Workspace.transition_task_r
           config
           ~agent_name:base_meta.agent_name
           ~task_id:created.task_id
           ~action:Masc_domain.Start
           ()
       with
       | Ok _ -> ()
       | Error err -> fail (Masc_domain.masc_error_to_string err));
      let task_id =
        match Keeper_id.Task_id.of_string created.task_id with
        | Ok task_id -> task_id
        | Error err -> fail err
      in
      let meta = { base_meta with current_task_id = Some task_id } in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "synthetic exhaustion");
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Heartbeat_consecutive_failures 9));
      let max_restarts =
        Masc.Runtime_params.get
          Masc.Governance_registry.keeper_supervisor_max_restarts
      in
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:max_restarts ~last_restart_ts:0.0 ~crash_log:[];
      let backlog_path = Masc.Workspace.backlog_path config in
      write_file backlog_path "{ not valid json";
      write_file (backlog_path ^ ".last-good") "{ not valid json";
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some persisted) ->
         check (option string)
           "dead keeper current_task_id preserved when discovery fails"
           (Some created.task_id)
           (Option.map Keeper_id.Task_id.to_string persisted.current_task_id)
       | Ok None -> fail "expected persisted keeper meta"
       | Error err -> fail err))

let with_reap_ready_dead_keeper name f =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Shutdown_finalize.For_testing.reset_remove_pending_confirms_by_target ();
      Shutdown_finalize.For_testing.reset_completion_handler ();
      Subprocess_registry.reset_for_testing ();
      Masc.Keeper_process_switch.For_testing.clear ();
      KLH.reset_for_testing ();
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      ignore (Reg.register ~base_path:config.base_path name meta);
      Reg.mark_dead ~base_path:config.base_path name ~at:0.0;
      let completion_bus =
        Agent_sdk.Event_bus.create ~policy:Agent_sdk.Event_bus.Drop_oldest ()
      in
      Masc_event_bus.set completion_bus;
      Subprocess_registry.register_default_cleanup_hook ();
      Shutdown_finalize.register_remove_pending_confirms_by_target
        (fun _config ~target_type:_ ~target_id:_ -> Ok 0);
      Shutdown_finalize.register_completion_handler Tombstone_cleanup.handle_completion;
      let run_sweep () =
        Eio.Switch.run @@ fun sw ->
        Sup.set_global_switch sw;
        let ctx : _ Keeper_types_profile.context =
          { config
          ; agent_name = supervisor_agent_name
          ; sw
          ; clock = Eio.Stdenv.clock env
          ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
          ; net = Some (Eio.Stdenv.net env)
          }
        in
        sweep_and_recover_no_materialize ctx
      in
      f ~config ~run_sweep)

let event_label = function
  | KLH.Tombstone_reaped -> "tombstone_reaped"
  | KLH.Phase_transition _ -> "phase_transition"

let test_sweep_and_recover_fires_tombstone_reaped_hook () =
  KLH.reset_for_testing ();
  let name = "tombstone-hook-keeper" in
  let fired = ref [] in
  KLH.register (fun ~keeper_id event ->
    fired := (keeper_id, event_label event) :: !fired);
  with_reap_ready_dead_keeper name @@ fun ~config ~run_sweep ->
  run_sweep ();
  check (list (pair string string))
    "single Tombstone_reaped event"
    [ (name, "tombstone_reaped") ] (List.rev !fired);
  check bool "dead keeper unregistered after tombstone cleanup"
    false (Reg.is_registered ~base_path:config.base_path name)

let test_sweep_and_recover_swallows_failing_tombstone_hook () =
  KLH.reset_for_testing ();
  let name = "tombstone-failing-hook-keeper" in
  let failing_hook_calls = ref 0 in
  let later_hook_events = ref [] in
  KLH.register (fun ~keeper_id:_ _ ->
    incr failing_hook_calls;
    raise (Failure "intentional tombstone hook failure"));
  KLH.register (fun ~keeper_id event ->
    later_hook_events := (keeper_id, event_label event) :: !later_hook_events);
  with_reap_ready_dead_keeper name @@ fun ~config ~run_sweep ->
  run_sweep ();
  check int "failing hook invoked exactly once" 1 !failing_hook_calls;
  check (list (pair string string))
    "later hook still observes Tombstone_reaped"
    [ (name, "tombstone_reaped") ] (List.rev !later_hook_events);
  check bool "dead keeper still unregistered after failing hook"
    false (Reg.is_registered ~base_path:config.base_path name)

(* ── Phase 2 (#10765): stale-termination storm auto-pause ──────── *)

(* Reproduces the Mode A failure pattern from 2026-04-27 fleet observation:
   keeper proactive turn fails (runtime dead / provider_timeout) → stale
   watchdog kills fiber → supervisor restarts → 30 min later same stale →
   restart loop with no operator-actionable signal beyond log ERROR.

   With Phase 2 latched as last_failure_reason = Stale_termination_storm,
   sweep_and_recover must:
   1. Skip [to_restart] enqueue (the regression we are preventing).
   2. Persist [meta.paused = true] on disk so reconcile + future sweeps
      respect the pause across server restarts.
   3. Increment [masc_keeper_stale_storm_paused_total] for observability.
   4. Leave [restart_count] unchanged (storm is not a restart attempt). *)
let test_stale_storm_pause_skips_restart () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "stale-storm-keeper" in
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "synthetic stale storm");
      (* [restore_supervisor_state] resets [last_failure_reason] to [None],
         so it MUST run before [set_failure_reason] (otherwise the storm
         latch is wiped and the supervisor sweeps the entry through the
         default crash path).  Order matters here. *)
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_termination_storm { count = 5 }));
      let baseline_pause =
        Masc.Otel_metric_store.metric_total "masc_keeper_stale_storm_paused_total"
      in
      let baseline_dead =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string DeadTotal)
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ~pacing_enforced:false ctx;
      let after_pause =
        Masc.Otel_metric_store.metric_total "masc_keeper_stale_storm_paused_total"
      in
      let after_dead =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string DeadTotal)
      in
      check (float 0.001) "stale_storm_paused counter incremented by 1"
        (baseline_pause +. 1.0) after_pause;
      check (float 0.001) "dead counter NOT incremented (storm is not death)"
        baseline_dead after_dead;
      (* meta.paused must be true on disk so reconcile + future sweeps
         honor the pause across server restarts. *)
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = true after storm pause"
             true m.paused;
           check bool "storm pause disables auto-resume"
             true (Option.is_none m.auto_resume_after_sec)
       | Ok None -> fail "meta missing after storm pause"
       | Error err -> fail ("read_meta failed: " ^ err));
      (* In-memory registry entry is unregistered so subsequent sweeps do
         NOT re-fire the storm-pause path within the same server instance.
         Reconcile_keepalive_keepers will skip this keeper on its next pass
         because [meta.paused = true]. *)
      check bool "registry entry unregistered after storm pause"
        false (Reg.is_registered ~base_path:config.base_path name))

let test_stale_storm_pause_releases_owned_task () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "stale-storm-task-owner" in
      let base_meta = make_meta name in
      let created =
        match
          Masc.Workspace.add_task_with_result
            config
            ~title:"auto-pause release regression"
            ~priority:1
            ~description:"task must be released when keeper auto-pauses"
        with
        | Ok created -> created
        | Error err -> fail (Masc.Workspace.add_task_error_to_string err)
      in
      (match
         Masc.Workspace.claim_task_r
           config
           ~agent_name:base_meta.agent_name
           ~task_id:created.task_id
           ()
       with
       | Ok _ -> ()
       | Error err -> fail (Masc_domain.masc_error_to_string err));
      (match
         Masc.Workspace.transition_task_r
           config
           ~agent_name:base_meta.agent_name
           ~task_id:created.task_id
           ~action:Masc_domain.Start
           ()
       with
       | Ok _ -> ()
       | Error err -> fail (Masc_domain.masc_error_to_string err));
      let task_id =
        match Keeper_id.Task_id.of_string created.task_id with
        | Ok task_id -> task_id
        | Error err -> fail err
      in
      let meta = { base_meta with current_task_id = Some task_id } in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "synthetic stale storm");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_termination_storm { count = 5 }));
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ~pacing_enforced:false ctx;
      let task =
        Masc.Workspace.get_tasks_raw config
        |> List.find (fun (task : Masc_domain.task) ->
          String.equal task.id created.task_id)
      in
      (match task.task_status with
       | Masc_domain.Todo -> ()
       | status ->
         fail
           (Printf.sprintf
              "expected auto-paused owner task to be todo, got %s"
              (Masc_domain.task_status_to_string status)));
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some persisted) ->
         check bool "auto-paused meta.paused=true" true persisted.paused;
         check (option string) "auto-paused current_task_id cleared" None
           (Option.map Keeper_id.Task_id.to_string persisted.current_task_id)
       | Ok None -> fail "expected persisted keeper meta"
       | Error err -> fail err))

let test_legacy_stale_fleet_batch_routes_to_restart_budget () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "legacy-stale-fleet-batch-keeper" in
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "legacy stale fleet batch");
      let max_restarts =
        Masc.Runtime_params.get
          Masc.Governance_registry.keeper_supervisor_max_restarts
      in
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:max_restarts ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_fleet_batch { distinct_count = 3 }));
      let baseline_dead =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string DeadTotal)
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      let after_dead =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string DeadTotal)
      in
      check (float 0.001) "legacy fleet batch follows restart/dead budget"
        (baseline_dead +. 1.0) after_dead;
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused stays false for legacy fleet batch"
             false m.paused
       | Ok None -> fail "meta missing after legacy fleet batch"
       | Error err -> fail ("read_meta failed: " ^ err));
      ())

let test_provider_timeout_loop_pause_skips_restart () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "provider-timeout-loop-keeper" in
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "synthetic provider timeout loop");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Provider_timeout_loop { count = 3 }));
      let baseline_pause =
        Masc.Otel_metric_store.metric_total
          "masc_keeper_provider_timeout_loop_paused_total"
      in
      let baseline_dead =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string DeadTotal)
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ~pacing_enforced:false ctx;
      let after_pause =
        Masc.Otel_metric_store.metric_total
          "masc_keeper_provider_timeout_loop_paused_total"
      in
      let after_dead =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string DeadTotal)
      in
      check (float 0.001) "provider_timeout_loop counter incremented by 1"
        (baseline_pause +. 1.0) after_pause;
      check (float 0.001) "dead counter NOT incremented (budget loop is pause)"
        baseline_dead after_dead;
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = true after provider timeout loop pause"
             true m.paused
       | Ok None -> fail "meta missing after provider timeout loop pause"
       | Error err -> fail ("read_meta failed: " ^ err));
      check bool "registry entry unregistered after provider timeout loop pause"
        false (Reg.is_registered ~base_path:config.base_path name))

(* ── #23439: turn-failure-streak auto-pause ──────────────────────── *)

(* [Keeper_failure_policy] returns a typed [Pause_keeper] verdict for a
   [Turn_failure_streak] (keeper_failure_policy.ml).  Before #23439 the
   supervisor re-matched [failure_reason] and routed
   [Turn_consecutive_failures] into [queue_standard_restart], discarding the
   verdict; the restart then zeroed [turn_consecutive_failures]
   (keeper_registry_setup.ml) so the identical "Keeper turn failed N
   consecutive cycle(s)" blocker regenerated every sweep.  sweep_and_recover
   must now:
   1. Skip the [to_restart] enqueue (no RestartAttempts for this keeper).
   2. Persist [meta.paused = true] on disk.
   3. Enable auto-resume with back-off ([auto_resume_after_sec = Some _],
      unlike the stale-storm manual pause which leaves it [None]).
   4. Increment [masc_keeper_turn_failure_streak_paused_total].
   5. Not mark the keeper dead. *)
let test_turn_failure_streak_pause_skips_restart () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "turn-failure-streak-keeper" in
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "synthetic turn failure streak");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Turn_consecutive_failures 3));
      let attempt_labels = [ ("keeper", name) ] in
      let baseline_pause =
        Masc.Otel_metric_store.metric_total
          "masc_keeper_turn_failure_streak_paused_total"
      in
      let baseline_dead =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string DeadTotal)
      in
      let baseline_restart_attempts =
        Masc.Otel_metric_store.metric_value_or_zero
          Keeper_metrics.(to_string RestartAttempts)
          ~labels:attempt_labels ()
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ~pacing_enforced:false ctx;
      let after_pause =
        Masc.Otel_metric_store.metric_total
          "masc_keeper_turn_failure_streak_paused_total"
      in
      let after_dead =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string DeadTotal)
      in
      let after_restart_attempts =
        Masc.Otel_metric_store.metric_value_or_zero
          Keeper_metrics.(to_string RestartAttempts)
          ~labels:attempt_labels ()
      in
      check (float 0.001) "turn_failure_streak_paused counter incremented by 1"
        (baseline_pause +. 1.0) after_pause;
      check (float 0.001)
        "restart attempt NOT incremented (Pause_keeper verdict honored)"
        baseline_restart_attempts after_restart_attempts;
      check (float 0.001) "dead counter NOT incremented (streak is a pause)"
        baseline_dead after_dead;
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = true after turn failure streak pause"
             true m.paused;
           check bool "turn failure streak pause enables auto-resume back-off"
             true (Option.is_some m.auto_resume_after_sec)
       | Ok None -> fail "meta missing after turn failure streak pause"
       | Error err -> fail ("read_meta failed: " ^ err));
      check bool "registry entry unregistered after turn failure streak pause"
        false (Reg.is_registered ~base_path:config.base_path name))

(* RFC-0313 W3 enforce twins: under the production default ([pacing]
   mode = "enforce" in config/runtime.toml), a [Pause_keeper] policy
   verdict must not flip existence — the sweep routes the keeper to the
   standard restart/backoff path instead.  The shadow tests above pass
   [~pacing_enforced:false] to pin the legacy pause arms until W4 deletes
   them (and those tests with them). *)
let run_enforced_pacing_restart_twin ~keeper_name ~reason ~pause_counter =
  with_restart_launch_noop @@ fun () ->
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_config_dir @@ fun config_dir ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_keepalive.stop_keepalive ~base_path:base_dir keeper_name;
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg =
        Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name)
      in
      write_keeper_toml config_dir ~name:keeper_name;
      let meta = make_meta keeper_name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path keeper_name meta in
      resolve_done_for_test reg (`Crashed "synthetic failure for enforce twin");
      Reg.restore_supervisor_state ~base_path:config.base_path keeper_name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path keeper_name (Some reason);
      let attempt_labels = [ ("keeper", keeper_name) ] in
      let baseline_pause = Masc.Otel_metric_store.metric_total pause_counter in
      let baseline_shadow =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string FailureDrivenPause)
      in
      let baseline_attempts =
        Masc.Otel_metric_store.metric_value_or_zero
          Keeper_metrics.(to_string RestartAttempts)
          ~labels:attempt_labels ()
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ~pacing_enforced:true ctx;
      check (float 0.001) "pause counter unchanged under enforce"
        baseline_pause
        (Masc.Otel_metric_store.metric_total pause_counter);
      check (float 0.001)
        "shadow FailureDrivenPause counter unchanged under enforce"
        baseline_shadow
        (Masc.Otel_metric_store.metric_total
           Keeper_metrics.(to_string FailureDrivenPause));
      check (float 0.001) "restart attempt queued instead of pause"
        (baseline_attempts +. 1.0)
        (Masc.Otel_metric_store.metric_value_or_zero
           Keeper_metrics.(to_string RestartAttempts)
           ~labels:attempt_labels ());
      (match Keeper_meta_store.read_meta config keeper_name with
       | Ok (Some m) ->
           check bool "meta.paused stays false under enforce" false m.paused
       | Ok None -> fail "meta missing after enforced sweep"
       | Error err -> fail ("read_meta failed: " ^ err)))

let test_enforced_pacing_routes_stale_storm_to_restart () =
  run_enforced_pacing_restart_twin
    ~keeper_name:"enforced-storm-restart-keeper"
    ~reason:(Reg.Stale_termination_storm { count = 5 })
    ~pause_counter:"masc_keeper_stale_storm_paused_total"

let test_enforced_pacing_routes_provider_timeout_loop_to_restart () =
  run_enforced_pacing_restart_twin
    ~keeper_name:"enforced-provider-timeout-restart-keeper"
    ~reason:(Reg.Provider_timeout_loop { count = 3 })
    ~pause_counter:"masc_keeper_provider_timeout_loop_paused_total"

let test_enforced_pacing_routes_turn_failure_streak_to_restart () =
  run_enforced_pacing_restart_twin
    ~keeper_name:"enforced-turn-streak-restart-keeper"
    ~reason:(Reg.Turn_consecutive_failures 3)
    ~pause_counter:"masc_keeper_turn_failure_streak_paused_total"

(* Fail-closed pause commit: when [paused=true] cannot be persisted (here:
   meta missing on disk), the pause must not commit — no pause counter, no
   Paused publish, and the registry entry must stay registered so the pause
   retries on the next sweep. Pre-fix the counter/publish fired
   unconditionally and the sweep unregistered the entry, after which
   reconcile relaunched a keeper operators saw as Paused. *)
let test_stale_storm_pause_persist_failure_keeps_entry_registered () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "stale-storm-persist-failure" in
      let meta = make_meta name in
      (* Intentionally NO [write_meta]: [handle_crash_auto_pause] cannot
         persist [paused=true] without an on-disk meta, so the pause must
         fail closed. *)
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "synthetic stale storm");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_termination_storm { count = 5 }));
      let baseline_pause =
        Masc.Otel_metric_store.metric_total "masc_keeper_stale_storm_paused_total"
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ~pacing_enforced:false ctx;
      let after_pause =
        Masc.Otel_metric_store.metric_total "masc_keeper_stale_storm_paused_total"
      in
      check (float 0.001) "pause counter NOT incremented on failed persist"
        baseline_pause after_pause;
      check bool "registry entry kept so the pause retries next sweep"
        true (Reg.is_registered ~base_path:config.base_path name))

(* Structural guard (precedent: test_keeper_pause_silent_failure_source.ml):
   in [Keeper_keepalive.start_keepalive], the [dispatch_fiber_started]
   launch gate must run BEFORE every launch side effect — the gRPC
   heartbeat starter and the live-meta bootstrap/update. A runtime repro
   is not reachable through the public surface ([register_offline] only
   runs when the keeper is unregistered, and a fresh registration accepts
   [Fiber_started]), so the ordering is pinned at the source level: if the
   gate moves back below the side effects, a rejected launch would again
   leave a live gRPC heartbeat behind a keeper the registry says never
   started. *)
let test_start_keepalive_gate_precedes_side_effects () =
  let load_source rel =
    let source_root =
      match Sys.getenv_opt "DUNE_SOURCEROOT" with
      | Some root -> root
      | None -> Sys.getcwd ()
    in
    let path = Filename.concat source_root rel in
    if not (Sys.file_exists path) then
      fail (Printf.sprintf "source file not found: %s" path)
    else
      In_channel.with_open_text path In_channel.input_all
  in
  let substring_index ~needle haystack =
    let nlen = String.length needle in
    let hlen = String.length haystack in
    let rec scan pos =
      if pos + nlen > hlen then None
      else if String.sub haystack pos nlen = needle then Some pos
      else scan (pos + 1)
    in
    if nlen = 0 then None else scan 0
  in
  let index_of ~what needle slice =
    match substring_index ~needle slice with
    | Some pos -> pos
    | None -> fail (Printf.sprintf "%s not found in start_keepalive body" what)
  in
  let source = load_source "lib/keeper/keeper_keepalive.ml" in
  let body_start =
    index_of ~what:"start_keepalive definition" "let start_keepalive" source
  in
  let body = String.sub source body_start (String.length source - body_start) in
  let gate = index_of ~what:"launch gate call" "dispatch_fiber_started ~base_path" body in
  let grpc =
    index_of ~what:"gRPC heartbeat starter call" "start_keeper_grpc_heartbeat ~ctx" body
  in
  let bootstrap =
    index_of ~what:"live meta bootstrap call" "bootstrap_live_keeper_meta ~ctx" body
  in
  check bool "launch gate precedes gRPC heartbeat starter" true (gate < grpc);
  check bool "launch gate precedes live-meta bootstrap" true (gate < bootstrap)

(* Fail-closed launch gate: a registry FSM in a terminal state rejects
   [Fiber_started]; the launch must abort without announcing
   [Started]/[Running], and the entry's done promise must resolve through
   the crash path so the sweep observes a typed outcome. Pre-fix the fiber
   forked and Running was published despite the reject. *)
let test_launch_rejected_terminal_state_does_not_announce_running () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "launch-reject-terminal" in
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      Reg.mark_dead ~base_path:config.base_path name ~at:(Unix.gettimeofday ());
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      Sup.with_restart_launch_noop_for_test (fun () ->
        match
          Masc.Keeper_supervisor_launch.launch_supervised_fiber
            ~proactive_warmup_sec:0 ctx meta reg
        with
        | Ok () -> fail "expected Fiber_started to be rejected in terminal state"
        | Error _ -> ());
      (match Reg.get_phase ~base_path:config.base_path name with
       | Some Keeper_state_machine.Dead -> ()
       | Some phase ->
         fail
           (Printf.sprintf "expected phase to stay Dead, got %s"
              (Keeper_state_machine.phase_to_string phase))
       | None -> fail "registry entry disappeared after rejected launch");
      check bool "done promise resolved through the crash path"
        true (Option.is_some (Eio.Promise.peek reg.done_p));
      check bool "rejected launch closes lane join contract"
        true (Reg.lane_has_exited reg))

(* Codex #24135 finding 5: a rejected [Keeper_lane.fork] (parent switch already
   cancelling, or [claim_start] refused) must propagate [Error] from
   [launch_supervised_fiber] and resolve the done promise through the crash
   path, so supervise/restart suppress [Started]/[Running] for a keeper whose
   lane was never forked. Pre-fix the fork error was [ignore]d and [Ok ()] was
   returned, letting the caller announce Running. Here the fork is refused
   deterministically by pre-claiming the lane; the registry FSM still accepts
   [Fiber_started], so this exercises the fork-rejection path (not the launch
   gate). *)
let test_launch_fork_rejection_does_not_announce_running () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg =
        Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name)
      in
      let name = "launch-fork-reject" in
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      (match
         Lane.reject_before_start reg.lane ~reason:(Failure "pre-claimed for test")
       with
       | Ok () -> ()
       | Error error -> fail (Lane.start_error_to_string error));
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      (match
         Masc.Keeper_supervisor_launch.launch_supervised_fiber
           ~proactive_warmup_sec:0 ctx meta reg
       with
       | Ok () -> fail "expected lane fork rejection to propagate as Error"
       | Error _ -> ());
      check bool
        "fork-rejected launch resolves done through the crash path"
        true
        (Option.is_some (Eio.Promise.peek reg.done_p));
      check bool
        "fork-rejected launch transitions the registry SSOT to Crashed"
        true
        (match Reg.get_phase ~base_path:config.base_path name with
         | Some KSM.Crashed -> true
         | Some _ | None -> false))

let test_fork_rejection_preserves_replacement_lane () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
      let name = "fork-reject-replacement" in
      let meta = make_meta name in
      let rejected = Reg.register ~base_path:config.base_path name meta in
      (match
         Lane.reject_before_start rejected.lane ~reason:(Failure "pre-claimed for test")
       with
       | Ok () -> ()
       | Error error -> fail (Lane.start_error_to_string error));
      let replacement = Reg.register ~base_path:config.base_path name meta in
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = supervisor_agent_name
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = Some (Eio.Stdenv.net env)
        }
      in
      (match
         Masc.Keeper_supervisor_launch.launch_supervised_fiber_body
           ~proactive_warmup_sec:0 ctx meta rejected
       with
       | Ok () -> fail "expected rejected lane to propagate as Error"
       | Error _ -> ());
      check bool
        "newer same-name lane remains the registry owner"
        true
        (match Reg.get ~base_path:config.base_path name with
         | Some current -> Lane.Id.equal (Lane.id current.lane) (Lane.id replacement.lane)
         | None -> false);
      check bool
        "rejected predecessor cannot terminalize replacement"
        true
        (match Reg.get_phase ~base_path:config.base_path name with
         | Some KSM.Running -> true
         | Some _ | None -> false))

let test_fork_rejection_unregisters_non_terminalizable_owner () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
      let name = "fork-reject-terminal-owner" in
      let meta = make_meta name in
      let rejected = Reg.register ~base_path:config.base_path name meta in
      Reg.mark_dead ~base_path:config.base_path name ~at:(Unix.gettimeofday ());
      (match
         Lane.reject_before_start rejected.lane ~reason:(Failure "pre-claimed for test")
       with
       | Ok () -> ()
       | Error error -> fail (Lane.start_error_to_string error));
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = supervisor_agent_name
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = Some (Eio.Stdenv.net env)
        }
      in
      (match
         Masc.Keeper_supervisor_launch.launch_supervised_fiber_body
           ~proactive_warmup_sec:0 ctx meta rejected
       with
       | Ok () -> fail "expected rejected terminal lane to propagate as Error"
       | Error _ -> ());
      check bool
        "non-terminalizable exact owner is unregistered"
        true
        (Option.is_none (Reg.get ~base_path:config.base_path name)))

let test_sweep_waits_for_lane_join_before_unregister () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
      let name = "joined-before-unregister" in
      let meta = make_meta name in
      let reg = Reg.register ~base_path:config.base_path name meta in
      ignore (Reg.dispatch_event ~base_path:config.base_path name KSM.Stop_requested);
      ignore (Reg.dispatch_event ~base_path:config.base_path name KSM.Drain_complete);
      ignore (Reg.resolve_done reg ~source:"test_unjoined_terminal" `Stopped);
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = supervisor_agent_name
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = Some (Eio.Stdenv.net env)
        }
      in
      sweep_and_recover_no_materialize ~pacing_enforced:false ctx;
      check bool
        "terminal event alone does not unregister lane"
        true
        (Reg.is_registered ~base_path:config.base_path name);
      (match
         Lane.reject_before_start reg.lane ~reason:(Failure "synthetic joined lane")
       with
       | Ok () -> ()
       | Error error -> fail (Lane.start_error_to_string error));
      sweep_and_recover_no_materialize ~pacing_enforced:false ctx;
      check bool
        "joined terminal lane is unregistered"
        false
        (Reg.is_registered ~base_path:config.base_path name))

let test_unresolved_watchdog_stopped_budget_loop_is_reaped () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "unresolved-watchdog-stopped" in
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      Atomic.set reg.fiber_stop true;
      (match
         Lane.reject_before_start
           reg.lane
           ~reason:(Failure "synthetic unresolved lane exit")
       with
       | Ok () -> ()
       | Error error -> fail (Lane.start_error_to_string error));
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Provider_timeout_loop { count = 3 }));
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ~pacing_enforced:false ctx;
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = true after unresolved watchdog stop"
             true m.paused;
           check bool "provider timeout blocker class preserved"
             true
             (match m.runtime.last_blocker with
              | Some b -> b.klass = Keeper_meta_contract.Turn_timeout
              | None -> false)
       | Ok None -> fail "meta missing after unresolved watchdog stop"
       | Error err -> fail ("read_meta failed: " ^ err));
      check bool "unresolved watchdog-stopped entry reaped"
        false (Reg.is_registered ~base_path:config.base_path name))

let test_stale_run_sweep_sets_watchdog_stop_signal () =
  with_restart_launch_noop @@ fun () ->
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "stale-run-stop-signal" in
      let base_meta = make_meta name in
      let meta =
        {
          base_meta with
          runtime =
            {
              base_meta.runtime with
              usage =
                {
                  base_meta.runtime.usage with
                  last_turn_ts = Unix.time () -. 3600.0;
                };
            };
        }
      in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      Reg.set_started_at_for_test
        ~base_path:config.base_path
        name
        (Unix.time () -. 3600.0);
      let max_restarts =
        Masc.Runtime_params.get
          Masc.Governance_registry.keeper_supervisor_max_restarts
      in
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:max_restarts ~last_restart_ts:0.0 ~crash_log:[];
      check bool "precondition: fiber_stop clear"
        false (Atomic.get reg.fiber_stop);
      check bool "precondition: fiber_wakeup clear"
        false (Atomic.get reg.fiber_wakeup);
      check bool "precondition: done unresolved"
        true (Option.is_none (Eio.Promise.peek reg.done_p));
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      with_env "MASC_KEEPER_STALE_RUN_SEC" "0.001" @@ fun () ->
      Unix.sleepf 0.02;
      sweep_and_recover_no_materialize ctx;
      check bool "stale sweep requests watchdog stop" true
        (Atomic.get reg.fiber_stop);
      check bool "stale sweep wakes keeper" true
        (Atomic.get reg.fiber_wakeup);
      check bool "first stale sweep leaves done unresolved" true
        (Option.is_none (Eio.Promise.peek reg.done_p));
      (match Reg.get ~base_path:config.base_path name with
       | Some updated ->
         (match updated.last_failure_reason with
          | Some (Reg.Stale_turn_timeout (Reg.Idle_turn { stall_seconds })) ->
            check bool "stale seconds is at least stale threshold"
              true (stall_seconds > 1800.0)
          | _ -> fail "expected idle stale-turn failure reason")
       | None -> fail "registry entry missing after first stale sweep");
      (match
         Lane.reject_before_start
           reg.lane
           ~reason:(Failure "synthetic watchdog lane exit")
       with
       | Ok () -> ()
       | Error error -> fail (Lane.start_error_to_string error));
      sweep_and_recover_no_materialize ctx;
      (match Reg.get ~base_path:config.base_path name with
       | Some updated ->
         check bool "second sweep marks exhausted stale keeper dead"
           true (updated.phase = KSM.Dead);
         (match Eio.Promise.peek updated.done_p with
         | Some (`Crashed msg) ->
            check bool "done reason preserves stale timeout"
              true (String.starts_with ~prefix:"stale_turn_timeout(" msg)
          | Some `Stopped -> fail "expected crashed watchdog resolution"
          | None -> fail "expected resolved watchdog crash")
       | None -> fail "registry entry missing after watchdog crash"))

(* Regression guard: a `Crashed entry whose last_failure_reason is NOT a
   storm must still flow through the existing restart-or-mark-dead branch.
   Verifies the new gate is variant-specific, not a blanket short-circuit. *)
let test_non_storm_crashed_restarts_normally () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "non-storm-keeper" in
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "ordinary crash");
      let max_restarts =
        Masc.Runtime_params.get
          Masc.Governance_registry.keeper_supervisor_max_restarts
      in
      (* Set restart_count to max_restarts so the default crash branch routes
         to [to_mark_dead] (not [to_restart]).  The point of this regression
         test is verifying the storm-gate is variant-specific, not exercising
         the restart path (which would fork a heartbeat fiber and hang). *)
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:max_restarts ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Heartbeat_consecutive_failures 3));
      let baseline_pause =
        Masc.Otel_metric_store.metric_total "masc_keeper_stale_storm_paused_total"
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      let after_pause =
        Masc.Otel_metric_store.metric_total "masc_keeper_stale_storm_paused_total"
      in
      check (float 0.001) "stale_storm_paused counter NOT incremented for non-storm"
        baseline_pause after_pause;
      (* meta.paused stays false. *)
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused stays false after non-storm crash"
             false m.paused
       | Ok None -> fail "meta missing"
       | Error err -> fail ("read_meta failed: " ^ err)))

(* ── Phase 3: self-healing circuit breaker ──────────────────── *)

(* Test: stale storm pause requires manual resume until root cause clears. *)
let test_storm_pause_requires_manual_resume () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "storm-manual-resume" in
      let meta = make_meta name in
      (* Ensure no prior auto_resume_after_sec. *)
      check bool "initial auto_resume_after_sec = None"
        true (meta.auto_resume_after_sec = None);
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "storm");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_termination_storm { count = 5 }));
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ~pacing_enforced:false ctx;
      (* Stale storms are operator-owned pauses: no timer should re-enter
         the same failed runtime/tool loop automatically. *)
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = true" true m.paused;
           check bool "auto_resume_after_sec remains None"
             true (Option.is_none m.auto_resume_after_sec);
           (* updated_at must be refreshed by the pause write so Phase 3.5
              timer (now - updated_at) is anchored to the pause time, not to
              some earlier heartbeat write. *)
           (match Workspace_resilience.Time.parse_iso8601_opt m.updated_at with
            | None ->
                fail (Printf.sprintf "updated_at not parseable as ISO-8601: %s"
                        m.updated_at)
            | Some paused_ts ->
                check bool "updated_at refreshed on pause (within last 5s)"
                  true (Unix.time () -. paused_ts < 5.0))
       | Ok None -> fail "meta missing after storm pause"
       | Error err -> fail ("read_meta failed: " ^ err)))

(* Test: exponential back-off still doubles for OAS timeout budget auto-pauses. *)
let test_oas_auto_resume_after_sec_doubles_on_repause () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "backoff-doubles" in
      (* Simulate a keeper that was already auto-paused with 1h delay. *)
      let initial_meta =
        { (make_meta name) with
          auto_resume_after_sec = Some 3600.0;
        }
      in
      (match Keeper_meta_store.write_meta config initial_meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name initial_meta in
      resolve_done_for_test reg (`Crashed "provider timeout loop");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Provider_timeout_loop { count = 3 }));
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ~pacing_enforced:false ctx;
      (* Back-off must double: 3600 -> 7200. *)
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = true" true m.paused;
           (match m.auto_resume_after_sec with
            | Some sec ->
                check (float 0.1) "auto_resume_after_sec doubled to 7200"
                  7200.0 sec
            | None -> fail "auto_resume_after_sec should be Some after repause")
       | Ok None -> fail "meta missing after repause"
       | Error err -> fail ("read_meta failed: " ^ err)))

(* Test: Phase 3.5 sweep auto-resumes a keeper whose timer has elapsed. *)
let test_sweep_auto_resumes_after_backoff () =
  with_restart_launch_noop @@ fun () ->
  ensure_test_runtime ();
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_config_dir @@ fun config_dir ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "auto-resume-keeper" in
      write_keeper_toml config_dir ~name;
      (* Simulate a keeper paused 2h ago with a 1h (3600s) auto-resume
         delay.  Since 7200 > 3600 the sweep should clear [paused]. *)
      let two_hours_ago =
        let t = Unix.gmtime (Unix.time () -. 7200.0) in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
          t.tm_hour t.tm_min t.tm_sec
      in
      let paused_meta =
        { (make_meta name) with
          paused = true;
          latched_reason =
            Some
              (Keeper_latched_reason.Operator_paused
                 { operator_actor = Keeper_latched_reason.operator_actor_keeper_down });
          auto_resume_after_sec = Some 3600.0;
          updated_at = two_hours_ago;
        }
      in
      (match Keeper_meta_store.write_meta config paused_meta with
       | Ok () -> ()
       | Error err -> fail err);
      check bool "precondition: paused keeper is not bootable" false
        (List.mem name (KR.bootable_keeper_names config));
      let baseline_auto_resume =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string AutoResumedTotal)
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      (* meta.paused must be cleared after the back-off timer elapsed. *)
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = false after auto-resume"
             false m.paused;
           (* auto_resume_after_sec is retained (ready for next pause). *)
           check bool "auto_resume_after_sec retained for next cycle"
             true (Option.is_some m.auto_resume_after_sec);
           check bool "latched_reason cleared after auto-resume"
             true (Option.is_none m.latched_reason);
           check bool "last_blocker cleared after auto-resume" true
             (Option.is_none m.runtime.last_blocker)
       | Ok None -> fail "meta missing after auto-resume"
       | Error err -> fail ("read_meta failed: " ^ err));
      check bool "auto-resumed keeper re-enters bootable set" true
        (List.mem name (KR.bootable_keeper_names config));
      check bool "auto-resumed keeper is reconciled into registry" true
        (Reg.is_registered ~base_path:config.base_path name);
      let after_auto_resume =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string AutoResumedTotal)
      in
      check (float 0.001) "metric_keeper_auto_resumed_total incremented by 1"
        (baseline_auto_resume +. 1.0) after_auto_resume)

let test_sweep_auto_resumes_registered_paused_entry () =
  ensure_test_runtime ();
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_config_dir @@ fun config_dir ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "auto-resume-registered" in
      write_keeper_toml config_dir ~name;
      let two_hours_ago =
        let t = Unix.gmtime (Unix.time () -. 7200.0) in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
          t.tm_hour t.tm_min t.tm_sec
      in
      let paused_meta =
        { (make_meta name) with
          paused = true;
          auto_resume_after_sec = Some 3600.0;
          updated_at = two_hours_ago;
        }
      in
      (match Keeper_meta_store.write_meta config paused_meta with
       | Ok () -> ()
       | Error err -> fail err);
      let entry = Reg.register ~base_path:config.base_path name paused_meta in
      (match Reg.dispatch_event ~base_path:config.base_path name KSM.Operator_pause with
       | Ok _ -> ()
       | Error err ->
           fail
             ("precondition: Operator_pause failed: "
              ^ KSM.transition_error_to_string err));
      (match Reg.get_phase ~base_path:config.base_path name with
       | Some phase ->
           check string "precondition: registry phase paused" "paused"
             (KSM.phase_to_string phase)
       | None -> fail "precondition: registry entry missing");
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused = false after auto-resume" false m.paused
       | Ok None -> fail "meta missing after auto-resume"
       | Error err -> fail ("read_meta failed: " ^ err));
      (match Reg.get_phase ~base_path:config.base_path name with
       | Some phase ->
           check string "registered keeper resumed in registry" "running"
             (KSM.phase_to_string phase)
       | None -> fail "registered keeper missing after auto-resume");
      check bool "auto-resume wakes existing keeper fiber" true
        (Atomic.get entry.Reg.fiber_wakeup))

(* Test: Phase-3 prune of a stale paused meta file also unregisters the
   registry entry. Without the unregister, the surviving entry is a ghost:
   still a board-wake candidate (Paused is accepted by
   [board_signal_entry_is_wakeup_candidate]) with no durable meta behind it,
   and any later [write_meta] through it resurrects the pruned file at
   meta_version=1 (RFC-0334 W3 census #23837, freshness caveat 1). Mirrors
   [keeper_down]'s remove_meta branch, which pairs [Sys.remove] with
   [unregister]. *)
let test_prune_stale_paused_meta_unregisters_entry () =
  ensure_test_runtime ();
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_config_dir @@ fun config_dir ->
  let base_dir = temp_dir () in
  let lifecycle_bus =
    Agent_sdk.Event_bus.create
      ~policy:Agent_sdk.Event_bus.Drop_oldest
      ()
  in
  let lifecycle_subscription =
    Agent_sdk.Event_bus.subscribe
      ~purpose:"stale-paused-prune-test"
      lifecycle_bus
  in
  Masc_event_bus.set lifecycle_bus;
  Fun.protect
    ~finally:(fun () ->
      Agent_sdk.Event_bus.unsubscribe lifecycle_bus lifecycle_subscription;
      Shutdown_finalize.For_testing.reset_remove_pending_confirms_by_target ();
      Shutdown_finalize.For_testing.reset_completion_handler ();
      Process_switch.For_testing.clear ();
      Tool_accumulator.drop_keeper_accumulator "stale-paused-prune";
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "stale-paused-prune" in
      Sup.set_global_switch sw;
      Shutdown_finalize.register_remove_pending_confirms_by_target
        (fun _config ~target_type:_ ~target_id:_ -> Ok 0);
      Shutdown_finalize.register_completion_handler
        Tombstone_cleanup.handle_completion;
      write_keeper_toml config_dir ~name;
      (* Just beyond the configured cleanup TTL, and
         [auto_resume_after_sec = None] keeps Phase 3.5 auto-resume out of
         the picture (operator pauses are never auto-resumed). *)
      let stale_timestamp =
        let t =
          Unix.gmtime
            (Unix.time () -. Env_config.KeeperSupervisor.paused_cleanup_ttl_sec
             -. 1.0)
        in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
          t.tm_hour t.tm_min t.tm_sec
      in
      let stale_meta =
        { (make_meta name) with
          paused = true;
          auto_resume_after_sec = None;
          updated_at = stale_timestamp;
        }
      in
      (match Keeper_meta_store.write_meta config stale_meta with
       | Ok () -> ()
       | Error err -> fail err);
      let _entry = Reg.register ~base_path:config.base_path name stale_meta in
      ignore (Tool_accumulator.accumulator_for_keeper name);
      (match Reg.dispatch_event ~base_path:config.base_path name KSM.Operator_pause with
       | Ok _ -> ()
       | Error err ->
           fail
             ("precondition: Operator_pause failed: "
              ^ KSM.transition_error_to_string err));
      let meta_path = Keeper_types_profile.keeper_meta_path config name in
      check bool "precondition: meta file on disk" true (Sys.file_exists meta_path);
      check bool "precondition: registered" true
        (Reg.is_registered ~base_path:config.base_path name);
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      let finalized =
        wait_until
          ~clock:ctx.clock
          ~deadline:(Eio.Time.now ctx.clock +. 2.0)
          (fun () ->
             (not (Sys.file_exists meta_path))
             && not (Reg.is_registered ~base_path:config.base_path name)
             &&
             match Shutdown_store.list_for_keeper ~config ~keeper_name:name with
             | Ok
                 [ { phase =
                       Shutdown_types.Finalized
                         { completion =
                             Shutdown_types.Completion_delivered
                               Shutdown_types.Paused_meta_pruned
                         ; _
                         }
                   ; _
                   } ] -> true
             | Ok _ | Error _ -> false)
      in
      check bool "durable paused prune finalized" true finalized;
      check bool "stale paused meta file pruned" false (Sys.file_exists meta_path);
      check bool "pruned keeper unregistered (no ghost wake candidate)" false
        (Reg.is_registered ~base_path:config.base_path name);
      check bool
        "pruned keeper accumulator dropped"
        false
        (List.mem name (Tool_accumulator.registered_keeper_names ()));
      (match Shutdown_store.list_for_keeper ~config ~keeper_name:name with
       | Ok
           [ { lane_ownership = Shutdown_types.Registered_lane _
             ; phase =
                 Shutdown_types.Finalized
                   { completion =
                       Shutdown_types.Completion_delivered
                         Shutdown_types.Paused_meta_pruned
                   ; registry_unregistered = true
                   ; accumulator_dropped = true
                   ; _
                   }
             ; _
             } ] -> ()
       | Ok _ -> fail "registered paused prune lost its durable final receipt"
       | Error error -> fail (Shutdown_store.error_to_string error));
      let paused_pruned_events =
        Agent_sdk.Event_bus.drain lifecycle_subscription
        |> List.filter (fun (event : Agent_sdk.Event_bus.event) ->
             match event.payload with
             | Agent_sdk.Event_bus.Custom
                 ("masc.keeper.lifecycle", `Assoc fields) ->
               List.assoc_opt "event" fields = Some (`String "paused_pruned")
             | _ -> false)
      in
      check int "paused prune completion event emitted once" 1
        (List.length paused_pruned_events))

let test_prune_stale_paused_dormant_meta_uses_durable_owner () =
  ensure_test_runtime ();
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_config_dir @@ fun config_dir ->
  let base_dir = temp_dir () in
  let lifecycle_bus =
    Agent_sdk.Event_bus.create
      ~policy:Agent_sdk.Event_bus.Drop_oldest
      ()
  in
  let lifecycle_subscription =
    Agent_sdk.Event_bus.subscribe
      ~purpose:"stale-paused-dormant-prune-test"
      lifecycle_bus
  in
  Masc_event_bus.set lifecycle_bus;
  let name = "stale-paused-dormant-prune" in
  Fun.protect
    ~finally:(fun () ->
      Agent_sdk.Event_bus.unsubscribe lifecycle_bus lifecycle_subscription;
      Shutdown_finalize.For_testing.reset_remove_pending_confirms_by_target ();
      Shutdown_finalize.For_testing.reset_completion_handler ();
      Process_switch.For_testing.clear ();
      Tool_accumulator.drop_keeper_accumulator name;
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg =
        Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name)
      in
      Sup.set_global_switch sw;
      Shutdown_finalize.register_remove_pending_confirms_by_target
        (fun _config ~target_type:_ ~target_id:_ -> Ok 0);
      Shutdown_finalize.register_completion_handler
        Tombstone_cleanup.handle_completion;
      write_keeper_toml config_dir ~name;
      let stale_timestamp =
        let t =
          Unix.gmtime
            (Unix.time () -. Env_config.KeeperSupervisor.paused_cleanup_ttl_sec
             -. 1.0)
        in
        Printf.sprintf
          "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (t.tm_year + 1900)
          (t.tm_mon + 1)
          t.tm_mday
          t.tm_hour
          t.tm_min
          t.tm_sec
      in
      let stale_meta =
        { (make_meta name) with
          paused = true
        ; latched_reason =
            Some
              (Latched_reason.Operator_paused
                 { operator_actor = Latched_reason.operator_actor_keeper_down })
        ; auto_resume_after_sec = None
        ; updated_at = stale_timestamp
        }
      in
      (match Keeper_meta_store.write_meta config stale_meta with
       | Ok () -> ()
       | Error error -> fail error);
      ignore (Tool_accumulator.accumulator_for_keeper name);
      check bool
        "precondition: dormant paused Keeper has no registry lane"
        false
        (Reg.is_registered ~base_path:config.base_path name);
      let meta_path = Keeper_types_profile.keeper_meta_path config name in
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = supervisor_agent_name
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = Some (Eio.Stdenv.net env)
        }
      in
      sweep_and_recover_no_materialize ctx;
      let finalized =
        wait_until
          ~clock:ctx.clock
          ~deadline:(Eio.Time.now ctx.clock +. 2.0)
          (fun () ->
             match Shutdown_store.list_for_keeper ~config ~keeper_name:name with
             | Ok
                 [ { lane_ownership = Shutdown_types.Dormant_meta
                   ; phase =
                       Shutdown_types.Finalized
                         { completion =
                             Shutdown_types.Completion_delivered
                               Shutdown_types.Paused_meta_pruned
                         ; meta_removed = true
                         ; registry_unregistered = false
                         ; accumulator_dropped = true
                         ; _
                         }
                   ; _
                   } ] -> true
             | Ok _ | Error _ -> false)
      in
      check bool "dormant paused prune finalized" true finalized;
      check bool "dormant paused meta removed" false (Sys.file_exists meta_path);
      check bool
        "dormant paused accumulator dropped"
        false
        (List.mem name (Tool_accumulator.registered_keeper_names ()));
      let paused_pruned_events =
        Agent_sdk.Event_bus.drain lifecycle_subscription
        |> List.filter (fun (event : Agent_sdk.Event_bus.event) ->
             match event.payload with
             | Agent_sdk.Event_bus.Custom
                 ("masc.keeper.lifecycle", `Assoc fields) ->
               List.assoc_opt "event" fields = Some (`String "paused_pruned")
             | _ -> false)
      in
      check int
        "dormant paused prune completion event emitted once"
        1
        (List.length paused_pruned_events))

(* Test: operator-paused keeper ([auto_resume_after_sec = None]) is NOT
   auto-resumed by the sweep — only the human can clear it. *)
let test_operator_pause_not_auto_resumed () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_config_dir @@ fun config_dir ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "operator-paused-keeper" in
      write_keeper_toml config_dir ~name;
      (* Paused 2h ago with NO auto_resume_after_sec (operator pause). *)
      let two_hours_ago =
        let t = Unix.gmtime (Unix.time () -. 7200.0) in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
          t.tm_hour t.tm_min t.tm_sec
      in
      let paused_meta =
        { (make_meta name) with
          paused = true;
          auto_resume_after_sec = None;   (* operator pause *)
          updated_at = two_hours_ago;
        }
      in
      (match Keeper_meta_store.write_meta config paused_meta with
       | Ok () -> ()
       | Error err -> fail err);
      check bool "precondition: operator pause is not bootable" false
        (List.mem name (KR.bootable_keeper_names config));
      let baseline_auto_resume =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string AutoResumedTotal)
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      (* meta.paused must remain true: operator pauses need human action. *)
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused stays true for operator pause"
             true m.paused
       | Ok None -> fail "meta missing"
       | Error err -> fail ("read_meta failed: " ^ err));
      check bool "operator pause remains out of bootable set" false
        (List.mem name (KR.bootable_keeper_names config));
      check bool "operator pause is not reconciled into registry" false
        (Reg.is_registered ~base_path:config.base_path name);
      let after_auto_resume =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string AutoResumedTotal)
      in
      check (float 0.001) "metric_keeper_auto_resumed_total NOT incremented"
        baseline_auto_resume after_auto_resume)

let test_turn_timeout_blocker_without_resume_policy_auto_recoverable () =
  let now = Unix.time () in
  let two_hours_ago =
    let t = Unix.gmtime (now -. 7200.0) in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
      t.tm_hour t.tm_min t.tm_sec
  in
  let timeout_blocker =
    Keeper_meta_contract.blocker_info_of_class
      ~detail:"turn_timeout"
      Keeper_meta_contract.Turn_timeout
  in
  let paused_meta =
    { (make_meta "timeout-paused-without-resume-policy") with
      paused = true
    ; auto_resume_after_sec = None
    ; updated_at = two_hours_ago
    ; runtime =
        { (make_meta "timeout-paused-without-resume-policy").runtime with
          last_blocker = Some timeout_blocker
        }
    }
  in
  check bool "timeout blocker without resume policy is due"
    true
    (Masc.Keeper_supervisor_types.paused_meta_auto_resume_due ~now paused_meta);
  check bool "implicit timeout auto-resume delay is present"
    true
    (Option.is_some
       (Masc.Keeper_supervisor_types.paused_meta_effective_auto_resume_after_sec
          paused_meta))

(* Regression guard for #17063/#17067: [auto_resume_after_sec = None] is the
   manual/operator pause contract.  A [Capacity_backpressure] blocker from old
   persisted metadata must not be treated as an implicit auto-resume policy. *)
let test_capacity_blocker_without_resume_policy_not_auto_resumed () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_config_dir @@ fun config_dir ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "capacity-paused-without-resume-policy" in
      write_keeper_toml config_dir ~name;
      let two_hours_ago =
        let t = Unix.gmtime (Unix.time () -. 7200.0) in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
          t.tm_hour t.tm_min t.tm_sec
      in
      let paused_meta =
        { (make_meta name) with
          paused = true;
          auto_resume_after_sec = None;
          updated_at = two_hours_ago;
          runtime =
            { (make_meta name).runtime with
              last_blocker =
                Some
                  (Keeper_meta_contract.blocker_info_of_class
                     ~detail:"capacity exhausted before explicit resume policy"
                     Keeper_meta_contract.Capacity_backpressure);
            };
        }
      in
      check bool "capacity blocker without resume policy is not due"
        false
        (Masc.Keeper_supervisor_types.paused_meta_auto_resume_due
           ~now:(Unix.time ())
           paused_meta);
      (match Keeper_meta_store.write_meta config paused_meta with
       | Ok () -> ()
       | Error err -> fail err);
      check bool "precondition: capacity pause is not bootable" false
        (List.mem name (KR.bootable_keeper_names config));
      let baseline_auto_resume =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string AutoResumedTotal)
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
        }
      in
      sweep_and_recover_no_materialize ctx;
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused stays true without explicit resume policy"
             true m.paused;
           check bool "capacity blocker stays recorded for operator inspection"
             true
             (match m.runtime.last_blocker with
              | Some info -> info.klass = Keeper_meta_contract.Capacity_backpressure
              | None -> false)
       | Ok None -> fail "meta missing"
       | Error err -> fail ("read_meta failed: " ^ err));
      check bool "capacity pause remains out of bootable set" false
        (List.mem name (KR.bootable_keeper_names config));
      check bool "capacity pause is not reconciled into registry" false
        (Reg.is_registered ~base_path:config.base_path name);
      let after_auto_resume =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string AutoResumedTotal)
      in
      check (float 0.001) "metric_keeper_auto_resumed_total NOT incremented"
        baseline_auto_resume after_auto_resume)

(* Regression test: initial delay is capped at max_sec even when
   MASC_KEEPER_AUTO_RESUME_INITIAL_SEC > MASC_KEEPER_AUTO_RESUME_MAX_SEC.
   The None -> initial_sec path must apply Float.min max_sec initial_sec. *)
let test_initial_auto_resume_capped_at_max () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "initial-cap-regression" in
      (* meta has no prior auto_resume_after_sec (first auto-pause). *)
      let meta = make_meta name in
      check bool "precondition: auto_resume_after_sec = None"
        true (meta.auto_resume_after_sec = None);
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "storm");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_termination_storm { count = 5 }));
      (* Use explicit values because Env_config values are module-level
         bindings and cannot be reloaded per test. *)
      let initial_sec = 35996400.0 in
      let max_sec = 3600.0 in
      let capped = Float.min max_sec initial_sec in
      check (float 0.001) "Float.min max_sec initial_sec = max_sec"
        3600.0 capped;
      check bool "initial > max is captured by Float.min"
        true (initial_sec > max_sec && capped = max_sec);
      (* Also exercise the production path directly by constructing the
         same expression the supervisor uses, without relying on env-lazy
         module values that can't be reloaded per-test. *)
      let auto_resume_after_sec =
        Sup.next_auto_resume_after_sec ~initial_sec ~max_sec
          meta.auto_resume_after_sec
      in
      (match auto_resume_after_sec with
       | None -> fail "expected Some after storm pause"
       | Some v ->
           check (float 0.001)
             "first auto-pause delay capped at max_sec even when initial > max"
             3600.0 v);
      ignore (sw, reg))

(* ── Test runner ────────────────────────────────────────── *)

let test_persisted_blocker_survives_unregister () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "auto-pause-blocker-keeper" in
      let meta = make_meta name in
      let meta =
        {
          meta with
          runtime =
            {
              meta.runtime with
              last_blocker = Some (Keeper_meta_contract.blocker_info_of_class ~detail:"test-blocker" Keeper_meta_contract.Turn_timeout);
            };
        }
      in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "storm");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_termination_storm { count = 5 }));
      let ctx : _ Keeper_types_profile.context =
        { config; agent_name = supervisor_agent_name; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env); net = Some (Eio.Stdenv.net env) }
      in
      sweep_and_recover_no_materialize ctx;
      
      (* Check if blocker is persisted *)
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           (match m.runtime.last_blocker with
            | Some b ->
                check string "meta.runtime.last_blocker" "test-blocker" b.detail;
                check bool "meta.runtime.last_blocker.klass" true (b.klass = Keeper_meta_contract.Turn_timeout)
            | None -> fail "expected blocker after storm pause");
       | Ok None -> fail "meta missing after storm pause"
       | Error err -> fail ("read_meta failed: " ^ err));
      
      (* Unregister the keeper *)
      Reg.unregister ~base_path:config.base_path name;
      
      (* Read again and verify *)
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           (match m.runtime.last_blocker with
            | Some b ->
                check string "meta.runtime.last_blocker after unregister" "test-blocker" b.detail;
                check bool "meta.runtime.last_blocker.klass after unregister" true (b.klass = Keeper_meta_contract.Turn_timeout)
            | None -> fail "expected blocker after unregister")
       | Ok None -> fail "meta missing after unregister"
       | Error err -> fail ("read_meta failed: " ^ err)))

(* RFC-0250: assess_stale_run — pure stale-run window assessment. Covers the
   [Idle_turn] variant's doc contract (Running + not-in-turn + last_turn_ts
   older than threshold) and the negative cases that must NOT stamp it. *)
let test_assess_stale_run () =
  (* frozen: Running, not in a turn, last turn 200s ago, threshold 150s →
     Some (Stale_turn_timeout (Idle_turn { stall_seconds = 200 })). *)
  (match
     Sup.assess_stale_run
       ~phase:KSM.Running
       ~in_turn:None
       ~last_turn_ts:100.0
       ~started_at:0.0
       ~now:300.0
       ~threshold:150.0
   with
   | Some (Reg.Stale_turn_timeout (Reg.Idle_turn { stall_seconds })) ->
     check int "frozen stamps Idle_turn stall=200" 200
       (int_of_float stall_seconds)
   | _ -> check bool "frozen must stamp Idle_turn{200}" false true);
  (* fresh: only 10s past last turn → None. *)
  check bool "fresh → None" true
    (Option.is_none
       (Sup.assess_stale_run
          ~phase:KSM.Running
          ~in_turn:None
          ~last_turn_ts:290.0
          ~started_at:0.0
          ~now:300.0
          ~threshold:150.0));
  (* fresh restart: metadata says the last completed turn is old, but the
     current supervised fiber has not had a full stale window yet. *)
  check bool "fresh restart with stale metadata -> None" true
    (Option.is_none
       (Sup.assess_stale_run
          ~phase:KSM.Running
          ~in_turn:None
          ~last_turn_ts:100.0
          ~started_at:280.0
          ~now:300.0
          ~threshold:150.0));
  (* restarted and stale: once the current supervised lifetime also exceeds the
     threshold, preserve the original stall value from last_turn_ts. *)
  (match
     Sup.assess_stale_run
       ~phase:KSM.Running
       ~in_turn:None
       ~last_turn_ts:100.0
       ~started_at:120.0
       ~now:300.0
       ~threshold:150.0
   with
   | Some (Reg.Stale_turn_timeout (Reg.Idle_turn { stall_seconds })) ->
     check int "restarted stale preserves last_turn stall=200" 200
       (int_of_float stall_seconds)
   | _ -> check bool "restarted stale must stamp Idle_turn{200}" false true);
  (* in-turn: a turn is live (Some _) → None — Idle_turn contract needs None. *)
  check bool "in-turn → None" true
    (Option.is_none
       (Sup.assess_stale_run
          ~phase:KSM.Running
          ~in_turn:(Some ())
          ~last_turn_ts:100.0
          ~started_at:0.0
          ~now:300.0
          ~threshold:150.0));
  (* fresh-start: last_turn_ts = 0 → None — never mis-stamp a just-started keeper. *)
  check bool "fresh-start (last_turn_ts=0) → None" true
    (Option.is_none
       (Sup.assess_stale_run
          ~phase:KSM.Running
          ~in_turn:None
          ~last_turn_ts:0.0
          ~started_at:290.0
          ~now:300.0
          ~threshold:150.0));
  (* not-running: Crashed → None. *)
  check bool "crashed → None" true
    (Option.is_none
       (Sup.assess_stale_run
          ~phase:KSM.Crashed
          ~in_turn:None
          ~last_turn_ts:100.0
          ~started_at:0.0
          ~now:300.0
          ~threshold:150.0));
  (* boundary: stall exactly == threshold → None (strict >). *)
  check bool "boundary stall==threshold → None" true
    (Option.is_none
       (Sup.assess_stale_run
          ~phase:KSM.Running
          ~in_turn:None
          ~last_turn_ts:150.0
          ~started_at:0.0
          ~now:300.0
          ~threshold:150.0))

let test_assess_in_turn_progress () =
  let make_turn_obs ~started_at ~last_progress_at ~last_progress_kind =
    let open Masc.Keeper_registry_types in
    ({ turn_id = 1
     ; started_at
     ; last_progress_at
     ; last_progress_kind
     ; active_tool_count = 0
     ; turn_phase = Packed Turn_prompting
     ; decision_stage = Packed Decision_undecided
     ; measurement = None
     ; measurement_bind_count = 0
     ; selected_model = None
     ; wake = Proactive_tick
     }
      : Masc.Keeper_registry_types.turn_observation)
  in
  (* RFC-0197 P1-4a: a turn_observation with [n] tools in flight, reusing
     [make_turn_obs] for the shared fields. *)
  let make_turn_obs_with_tools ~active_tool_count ~started_at ~last_progress_at
        ~last_progress_kind =
    { (make_turn_obs ~started_at ~last_progress_at ~last_progress_kind) with
      Masc.Keeper_registry_types.active_tool_count
    }
  in
  (* hung mid-turn: Running, turn live, last progress 400s ago, threshold 300s →
     Some (Stale_turn_timeout (Mid_turn_no_progress { since_progress=400 })). *)
  (match
     Sup.assess_in_turn_progress
       ~phase:KSM.Running
       ~in_turn:
         (Some
            (make_turn_obs
               ~started_at:1000.0
               ~last_progress_at:1000.0
               ~last_progress_kind:(Some "tool_completed:foo")))
       ~now:1400.0
       ~progress_timeout:300.0
   with
   | Some
       (Reg.Stale_turn_timeout
          (Reg.Mid_turn_no_progress
             { since_progress_seconds
             ; active_seconds
             ; progress_timeout_threshold
             ; last_progress_kind
             })) ->
     check int "since_progress=400" 400 (int_of_float since_progress_seconds);
     check int "active=400" 400 (int_of_float active_seconds);
     check int "threshold=300" 300 (int_of_float progress_timeout_threshold);
     check
       (option string)
       "last_progress_kind preserved"
       (Some "tool_completed:foo")
       last_progress_kind
   | _ -> check bool "hung must stamp Mid_turn_no_progress{400}" false true);
  (* progressing: last progress only 100s ago → None. *)
  check bool "recent progress → None" true
    (Option.is_none
       (Sup.assess_in_turn_progress
          ~phase:KSM.Running
          ~in_turn:
            (Some
               (make_turn_obs
                  ~started_at:1000.0
                  ~last_progress_at:1300.0
                  ~last_progress_kind:(Some "tool_completed:bar")))
          ~now:1400.0
          ~progress_timeout:300.0));
  (* boundary: since_progress exactly == threshold → None (strict >). *)
  check bool "boundary since==threshold → None" true
    (Option.is_none
       (Sup.assess_in_turn_progress
          ~phase:KSM.Running
          ~in_turn:
            (Some
               (make_turn_obs
                  ~started_at:1000.0
                  ~last_progress_at:1000.0
                  ~last_progress_kind:None))
          ~now:1300.0
          ~progress_timeout:300.0));
  (* no turn in progress → None (mid-turn contract needs Some obs). *)
  check bool "no turn → None" true
    (Option.is_none
       (Sup.assess_in_turn_progress
          ~phase:KSM.Running
          ~in_turn:None
          ~now:9999.0
          ~progress_timeout:300.0));
  (* not-running: Crashed with a silent turn → None. *)
  check bool "crashed → None" true
    (Option.is_none
       (Sup.assess_in_turn_progress
          ~phase:KSM.Crashed
          ~in_turn:
            (Some
               (make_turn_obs
                  ~started_at:1000.0
                  ~last_progress_at:1000.0
                  ~last_progress_kind:None))
          ~now:1400.0
          ~progress_timeout:300.0));
  (* RFC-0197 P1-4a: a tool in flight is active tool execution, not no-progress.
     Same stale 400s>300s window as the hung case above, but active_tool_count=1
     suppresses the producer → None. *)
  check bool "tool in flight → None (not no-progress)" true
    (Option.is_none
       (Sup.assess_in_turn_progress
          ~phase:KSM.Running
          ~in_turn:
            (Some
               (make_turn_obs_with_tools
                  ~active_tool_count:1
                  ~started_at:1000.0
                  ~last_progress_at:1000.0
                  ~last_progress_kind:(Some "tool_completed:foo")))
          ~now:1400.0
          ~progress_timeout:300.0));
  (* The suppression is count-gated, not timing: a long silent tool stays
     excluded no matter how far past the threshold. This is the exact invariant
     the removed RFC-0125 P4 max-turn wall-clock watchdog violated: that
     [Eio.Fiber.first] timer would have force-restarted this long-but-healthy
     tool turn on keeper *lifetime* (now - launch), not on per-turn stall. After
     its removal (RFC-0250 alignment), recovery relies only on no-progress
     ([Mid_turn_no_progress]) + no-turn ([Idle_turn]); a turn making progress is
     never killed by a wall-clock cap. Treat a regression here as a signal that a
     lifetime/wall-clock watchdog was re-introduced. *)
  check bool "tool in flight far past threshold → None" true
    (Option.is_none
       (Sup.assess_in_turn_progress
          ~phase:KSM.Running
          ~in_turn:
            (Some
               (make_turn_obs_with_tools
                  ~active_tool_count:3
                  ~started_at:1000.0
                  ~last_progress_at:1000.0
                  ~last_progress_kind:None))
          ~now:10000.0
          ~progress_timeout:300.0));
  (* Once the tools complete (count back to 0) a genuinely stalled turn still
     produces Mid_turn_no_progress, so the gate suppresses only while in flight. *)
  (match
     Sup.assess_in_turn_progress
       ~phase:KSM.Running
       ~in_turn:
         (Some
            (make_turn_obs
               ~started_at:1000.0
               ~last_progress_at:1000.0
               ~last_progress_kind:(Some "tool_completed:foo")))
       ~now:1400.0
       ~progress_timeout:300.0
   with
   | Some (Reg.Stale_turn_timeout (Reg.Mid_turn_no_progress _)) -> ()
   | _ ->
     check bool "count back to 0 still fires no-progress" false true)

let () =
  run "keeper_supervisor" [
    "backoff", [
      test_case "attempt 0 = base" `Quick test_backoff_delay_attempt_0;
      test_case "exponential growth" `Quick test_backoff_delay_exponential;
      test_case "cap at max" `Quick test_backoff_delay_cap;
      test_case "first auto-resume delay capped at max" `Quick
        test_auto_resume_first_delay_capped;
      test_case "auto-resume disabled by zero initial delay" `Quick
        test_auto_resume_disabled;
    ];
    "keep_last_n", [
      test_case "under limit" `Quick test_keep_last_n_under_limit;
      test_case "at limit" `Quick test_keep_last_n_at_limit;
      test_case "over limit drops oldest" `Quick test_keep_last_n_over_limit;
    ];
    "persona_drift", [
      test_case "drift check honors TOML persona_name" `Quick
        test_persona_drift_check_uses_toml_persona_name;
      test_case "drift check preserves invalid config" `Quick
        test_persona_drift_check_preserves_invalid_config;
      test_case "drift path points to profile.json" `Quick
        test_persona_drift_path_points_to_profile_json;
      test_case "missing persona with inline TOML is WARN" `Quick
        test_missing_persona_with_inline_toml_is_warn;
      test_case "missing persona without TOML is ERROR" `Quick
        test_missing_persona_without_profile_or_toml_is_error;
    ];
    "boot_meta_materialization", [
      test_case "declarative boot derives missing goal from instructions" `Quick
        test_declarative_boot_materializes_goal_from_instructions;
      test_case "declarative boot records goal-required failure" `Quick
        test_declarative_boot_records_goal_required_failure;
      test_case "declarative boot records typed invalid-config failure" `Quick
        test_declarative_boot_records_typed_invalid_config_failure;
      test_case "reconcile materializes configured keeper without meta" `Quick
        test_reconcile_materializes_configured_keeper_without_meta;
      test_case "reconcile does not double-start materialized keeper" `Quick
        test_reconcile_does_not_double_start_materialized_keeper;
      test_case "reconcile repairs persisted no-progress paused task owner" `Quick
        test_reconcile_repairs_persisted_no_progress_paused_task_owner;
      test_case "reconcile keeps manual paused task owner" `Quick
        test_reconcile_keeps_manual_paused_task_owner;
      test_case "reconcile materialize failure is isolated and metriced" `Quick
        test_reconcile_materialize_failure_continues_with_metric;
      test_case "reconcile supervise exception is isolated" `Quick
        test_reconcile_supervise_exception_continues;
    ];
    "fiber_health", [
      test_case "unknown for unregistered" `Quick test_fiber_health_unknown;
      test_case "registry count zero" `Quick test_registry_count_initially_zero;
      test_case "crash_log empty" `Quick test_crash_log_empty_for_unknown;
      test_case "should cleanup dead when ttl exceeded" `Quick test_should_cleanup_dead_true;
      test_case "should not cleanup dead when recent" `Quick test_should_cleanup_dead_false_when_recent;
    ];
    "backoff_properties", [
      test_case "monotonic until cap" `Quick test_backoff_monotonic_until_cap;
      test_case "never negative" `Quick test_backoff_never_negative;
    ];
    "failure_policy_bridge", [
      test_case "watchdog provider timeout loop pauses via policy" `Quick
        test_supervisor_policy_pauses_watchdog_provider_timeout_loop;
      test_case "stale storm pauses via policy" `Quick
        test_supervisor_policy_pauses_stale_storm;
      test_case "stale turn restarts via policy" `Quick
        test_supervisor_policy_restarts_stale_turn;
      test_case "runtime-exhausted transient/bounded reasons are retryable" `Quick
        test_supervisor_policy_runtime_exhausted_retryable_reasons;
      test_case "runtime-exhausted capability/unknown reasons are terminal" `Quick
        test_supervisor_policy_runtime_exhausted_terminal_reasons;
      test_case "provider timeout catch-all is retryable" `Quick
        test_supervisor_policy_provider_timeout_catch_all_retries;
      test_case "provider error with reason=None falls through to no decision" `Quick
        test_supervisor_policy_runtime_error_no_reason_falls_through;
    ];
    "keep_last_n_properties", [
      test_case "never exceeds limit" `Quick test_keep_last_n_never_exceeds;
    ];
    "done_signal", [
      test_case "publish only for fresh resolution" `Quick
        test_done_signal_publishes_only_for_fresh_resolution;
      test_case "registry result mapping preserves lifecycle ownership" `Quick
        test_done_signal_maps_registry_result;
    ];
    "supervision_cohorts", [
      test_case "64 keepers form 8 cohorts of 8" `Quick
        test_supervision_cohorts_64_keepers_8x8;
      test_case "custom size and floor" `Quick
        test_supervision_cohorts_custom_size_and_floor;
      test_case "large custom size yields between cohorts only" `Quick
        test_supervision_cohorts_large_custom_size_yields_between_only;
      test_case "fresh cohort entries are re-read by name" `Quick
        test_fresh_supervision_cohort_keepers_rereads_registry;
      test_case "restart launch noop scoped restore" `Quick
        test_restart_launch_noop_scope_restores_nested_state;
      test_case "spawn admission denial does not register or fork" `Quick
        test_spawn_admission_denial_does_not_register_or_fork;
      test_case "active count uses current entries" `Quick
        test_active_supervision_keeper_count_uses_current_entries;
    ];
    "self_preservation_properties", [
      test_case "output subset of input" `Quick test_self_preservation_subset;
      test_case "empty input → empty output" `Quick test_self_preservation_empty_input;
      test_case "bounded partial stale recovery cohort allowed" `Quick
        test_self_preservation_allows_bounded_partial_stale_recovery;
      test_case "mixed partial stale recovery keeps full restart set" `Quick
        test_self_preservation_allows_mixed_partial_stale_recovery;
      test_case "large partial stale recovery cohort suppressed" `Quick
        test_self_preservation_suppresses_large_partial_stale_recovery;
      test_case "universal stale recovery cohort suppressed" `Quick
        test_self_preservation_suppresses_universal_stale_recovery;
      test_case "partial suppression warns on cadence" `Quick
        test_self_preservation_partial_suppression_warn_cadence;
    ];
    "runtime_override", [
      test_case "fiber_health_of respects max_restarts override" `Quick
        test_fiber_health_respects_max_restarts_override;
    ];
    "reconcile_gate_recovery", [
      test_case "pending HITL approval names include only persisted keepers" `Quick
        test_pending_hitl_approval_keeper_names_filters_persisted_pending;
      test_case "sweep restores reconcile gate for paused keeper" `Quick
        test_sweep_restores_reconcile_gate_for_paused_keeper;
      test_case "sweep warns for pending HITL approval" `Quick
        test_sweep_reports_pending_hitl_approval;
    ];
    "restart_metrics", [
      test_case "restart path emits attempt and started outcome metrics" `Quick
        test_restart_path_emits_attempt_and_started_outcome_metrics;
      test_case "restart path emits missing-meta outcome metrics" `Quick
        test_restart_path_emits_meta_unavailable_outcome_metric;
      test_case "restart denies persisted dead tombstone" `Quick
        test_restart_denies_persisted_dead_tombstone;
    ];
    "dead_state_alert", [
      test_case "max_restarts exhaustion emits Dead alert" `Quick
        test_max_restarts_exhaustion_emits_dead_alert;
      test_case "max_restarts exhaustion releases owned task" `Quick
        test_max_restarts_exhaustion_releases_owned_task;
      test_case
        "max_restarts exhaustion preserves current_task_id when owned task query fails"
        `Quick
        test_max_restarts_exhaustion_preserves_current_task_when_owned_task_query_fails;
      test_case "stale storm auto-pause releases owned task" `Quick
        test_stale_storm_pause_releases_owned_task;
      test_case "sweep cleanup fires Tombstone_reaped hook" `Quick
        test_sweep_and_recover_fires_tombstone_reaped_hook;
      test_case "failing Tombstone_reaped hook is swallowed" `Quick
        test_sweep_and_recover_swallows_failing_tombstone_hook;
    ];
    "stale_storm_phase2", [
      test_case "Stale_termination_storm skips restart, persists paused, increments counter" `Quick
        test_stale_storm_pause_skips_restart;
      test_case "legacy Stale_fleet_batch follows restart budget" `Quick
        test_legacy_stale_fleet_batch_routes_to_restart_budget;
      test_case "Provider timeout loop skips restart, persists paused, increments counter" `Quick
        test_provider_timeout_loop_pause_skips_restart;
      test_case "Turn failure streak honors Pause_keeper verdict, skips restart (#23439)" `Quick
        test_turn_failure_streak_pause_skips_restart;
      test_case "enforced pacing routes stale storm to restart (RFC-0313 W3)" `Quick
        test_enforced_pacing_routes_stale_storm_to_restart;
      test_case "enforced pacing routes provider timeout loop to restart (RFC-0313 W3)"
        `Quick test_enforced_pacing_routes_provider_timeout_loop_to_restart;
      test_case "enforced pacing routes turn failure streak to restart (RFC-0313 W3)"
        `Quick test_enforced_pacing_routes_turn_failure_streak_to_restart;
      test_case "storm pause persist failure keeps entry registered (fail-closed)" `Quick
        test_stale_storm_pause_persist_failure_keeps_entry_registered;
      test_case "terminal-state launch reject does not announce Running" `Quick
        test_launch_rejected_terminal_state_does_not_announce_running;
      test_case "lane fork reject does not announce Running" `Quick
        test_launch_fork_rejection_does_not_announce_running;
      test_case "fork reject preserves newer same-name lane" `Quick
        test_fork_rejection_preserves_replacement_lane;
      test_case "fork reject unregisters non-terminalizable exact owner" `Quick
        test_fork_rejection_unregisters_non_terminalizable_owner;
      test_case "sweep joins lane before unregister" `Quick
        test_sweep_waits_for_lane_join_before_unregister;
      test_case "start_keepalive launch gate precedes side effects (source guard)" `Quick
        test_start_keepalive_gate_precedes_side_effects;
      test_case "unresolved watchdog-stopped budget loop is reaped" `Quick
        test_unresolved_watchdog_stopped_budget_loop_is_reaped;
      test_case "stale run sweep sets watchdog stop signal" `Quick
        test_stale_run_sweep_sets_watchdog_stop_signal;
      test_case "non-storm Crashed still routes to restart (regression guard)" `Quick
        test_non_storm_crashed_restarts_normally;
    ];
    "self_healing_circuit_breaker", [
      test_case "storm pause requires manual resume" `Quick
        test_storm_pause_requires_manual_resume;
      test_case "OAS auto_resume_after_sec doubles on successive auto-pauses" `Quick
        test_oas_auto_resume_after_sec_doubles_on_repause;
      test_case "sweep auto-resumes keeper when timer elapsed" `Quick
        test_sweep_auto_resumes_after_backoff;
      test_case "sweep auto-resumes registered paused keeper in registry" `Quick
        test_sweep_auto_resumes_registered_paused_entry;
      test_case "prune of stale paused meta unregisters the registry entry" `Quick
        test_prune_stale_paused_meta_unregisters_entry;
      test_case "prune of stale dormant paused meta keeps a durable owner" `Quick
        test_prune_stale_paused_dormant_meta_uses_durable_owner;
      test_case "operator pause (None) is NOT auto-resumed by sweep" `Quick
        test_operator_pause_not_auto_resumed;
      test_case "turn timeout blocker without resume policy is auto-recoverable"
        `Quick test_turn_timeout_blocker_without_resume_policy_auto_recoverable;
      test_case "capacity blocker without resume policy is NOT auto-resumed"
        `Quick test_capacity_blocker_without_resume_policy_not_auto_resumed;
      test_case "initial delay capped at max_sec when initial > max (regression)" `Quick
        test_initial_auto_resume_capped_at_max;
      test_case "persisted blocker survives unregister" `Quick
        test_persisted_blocker_survives_unregister;
    ];
    "stale_run_window", [
      test_case
        "assess_stale_run covers frozen/fresh/restart/in-turn/fresh-start/not-running/boundary"
        `Quick test_assess_stale_run;
    ];
    "mid_turn_progress_window", [
      test_case
        "assess_in_turn_progress covers hung/progressing/boundary/no-turn/not-running"
        `Quick test_assess_in_turn_progress;
    ];
  ]
