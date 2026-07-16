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
module KA = Masc.Keeper_keepalive
module KSR = Masc.Keeper_supervisor_reconcile_keepalive
module Supervisor_launch = Masc.Keeper_supervisor_launch
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
instructions = "test keeper"
sandbox_profile = "local"
|}
       name)

let write_keeper_toml_with_instructions config_dir ~name ~instructions =
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

let write_empty_keeper_toml config_dir ~name =
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
        ("sandbox_profile", `String "local");
        ("network_mode", `String "inherit");
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
        ("sandbox_profile", `String "local");
        ("network_mode", `String "inherit");
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

(* Shared pure supervisor fixtures. *)

let bp = "/tmp/test-supervisor-prop"
let make_meta name =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-" ^ name));
    ("sandbox_profile", `String "local");
    ("network_mode", `String "inherit");
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

let sweep_and_recover_no_materialize ctx =
  Sup.sweep_and_recover
    ~load_or_materialize_keeper_meta:noop_load_or_materialize_keeper_meta
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
               ~decision:(AQ.Decision.Reject "test cleanup")))
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
          match
            AQ.submit_pending
              ~keeper_name
              ~tool_name:"test_pending_gate_request"
              ~input:(`Assoc [])
              ~base_path:config.base_path
              ()
          with
          | Ok id -> id
          | Error error -> fail (AQ.storage_error_to_string error)
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
instructions = "plan coding work"
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
instructions = "inline keeper metadata is enough to run"
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

let publication_recovery_registry env sw config =
  let registry_root =
    Eio.Path.(Eio.Stdenv.fs env / Masc.Workspace.masc_root_dir config)
  in
  match
    Fs_compat.Publication_recovery.open_registry
      ~sw
      ~fs:(Eio.Stdenv.fs env)
      ~registry_root
  with
  | Ok registry -> registry
  | Error error ->
    fail
      (Fs_compat.Publication_recovery.registry_error_to_string error)

let keeper_runtime_context env sw config : _ Keeper_types_profile.context =
  { config
  ; agent_name = supervisor_agent_name
  ; sw
  ; clock = Eio.Stdenv.clock env
  ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
  ; net = Some (Eio.Stdenv.net env)
  ; publication_recovery_provider =
      Masc_test_deps.publication_recovery_provider
        (publication_recovery_registry env sw config)
  }

let latest_log_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> entry.seq
  | [] -> -1

let test_declarative_boot_materializes_instructions () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let name = "intent-only" in
  let instructions = "watch fleet safety and repair keeper bootstrap" in
  write_keeper_toml_with_instructions config_dir ~name ~instructions;
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
      check string "instructions preserved" instructions
        resolution.meta.instructions;
      check bool "boot failure cleared" true
        (Option.is_none
           (KR.boot_meta_failure_for ~base_path:config.base_path ~name)))

let test_declarative_boot_allows_empty_goal_links () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let name = "empty-intent" in
  write_empty_keeper_toml config_dir ~name;
  Eio.Switch.on_release sw (fun () ->
      Reg.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let ctx = keeper_runtime_context env sw config in
  Fun.protect
    ~finally:(fun () -> KR.stop_keepalive ~base_path:config.base_path name)
    (fun () ->
      (match KR.load_or_materialize_boot_meta ctx name with
       | Error err -> fail err
       | Ok resolution ->
         check bool "empty-goal keeper materialized" true resolution.materialized;
         check (list string) "no active goal links" [] resolution.meta.active_goal_ids);
      check bool "no boot failure recorded" true
        (Option.is_none (KR.boot_meta_failure_for ~base_path:config.base_path ~name)))

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

(* ── Runtime override: fiber_health_of ─────────────────── *)


let test_sweep_does_not_synthesize_gate_from_runtime_blocker () =
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
                     ~detail:"provider turn timed out"
                     Keeper_meta_contract.Stale_turn_timeout);
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      let pending_before = AQ.pending_count () in
      sweep_and_recover_no_materialize ctx;
      check bool "paused keeper has no synthetic approval" false
        (AQ.has_pending_for_keeper ~keeper_name:meta.name);
      check int "approval count unchanged" pending_before (AQ.pending_count ());
      let persisted_meta =
        match Keeper_meta_store.read_meta config meta.name with
        | Ok (Some value) -> value
        | Ok None -> fail "expected persisted keeper meta"
        | Error err -> fail err
      in
      check bool "sweep does not reinterpret pause" true persisted_meta.paused;
      check bool "blocker remains diagnostic evidence" true
        (Option.is_some persisted_meta.runtime.last_blocker))

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
                ~decision:(AQ.Decision.Reject "test cleanup")))
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
      let id =
        match
          AQ.submit_pending
            ~keeper_name:name
            ~tool_name:"test_pending_gate_request"
            ~input:(`Assoc [ ("kind", `String "visibility_probe") ])
            ~base_path:config.base_path
            ()
        with
        | Ok id -> id
        | Error error -> fail (AQ.storage_error_to_string error)
      in
      approval_id := Some id;
      let baseline = latest_log_seq () in
      let ctx = keeper_runtime_context env sw config in
      sweep_and_recover_no_materialize ctx;
      let expected =
        Printf.sprintf
          "keeper:%s has 1 pending HITL request(s); Keeper lane remains available"
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
      (match AQ.resolve ~id ~decision:AQ.Decision.Approve with
       | Ok () -> approval_id := None
       | Error err -> fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
      check bool "resolution removes pending request" false
        (AQ.has_pending_for_keeper ~keeper_name:name))

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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
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
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config)
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
      let completion_bus = Agent_sdk.Event_bus.create () in
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
          ; publication_recovery_provider =
              Masc_test_deps.publication_recovery_provider
                (publication_recovery_registry env sw config)
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

(* Legacy stale-fleet observations use the same per-lane restart path as
   every other crashed lane. They never synthesize pause or Dead. *)
let test_legacy_stale_fleet_batch_routes_to_restart () =
  with_restart_launch_noop @@ fun () ->
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
      let name = "legacy-stale-fleet-batch-keeper" in
      write_keeper_toml config_dir ~name;
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "legacy stale fleet batch");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:50 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_fleet_batch { distinct_count = 3 }));
      let baseline_restart =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string RestartAttempts)
      in
      let ctx : _ Keeper_types_profile.context =
        {
          config;
          agent_name = supervisor_agent_name;
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = Some (Eio.Stdenv.net env);
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      sweep_and_recover_no_materialize ctx;
      let after_restart =
        Masc.Otel_metric_store.metric_total
          Keeper_metrics.(to_string RestartAttempts)
      in
      check (float 0.001) "legacy fleet batch restarts after many failures"
        (baseline_restart +. 1.0) after_restart;
      (match Reg.get ~base_path:config.base_path name with
       | Some entry -> check bool "lane never becomes Dead" false (entry.phase = KSM.Dead)
       | None -> fail "registry entry missing after restart");
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           check bool "meta.paused stays false for legacy fleet batch"
             false m.paused
       | Ok None -> fail "meta missing after legacy fleet batch"
       | Error err -> fail ("read_meta failed: " ^ err));
      ())

exception Synthetic_cleanup_failure

let test_supervisor_cleanup_suppresses_cancellation_and_classifies_failures () =
  (match
     Supervisor_launch.run_cleanup_best_effort (fun () ->
       raise (Eio.Cancel.Cancelled (Failure "synthetic cleanup cancellation")))
   with
   | Supervisor_launch.Cleanup_cancelled -> ()
   | Supervisor_launch.Cleanup_completed -> fail "cancellation was reported as completed"
   | Supervisor_launch.Cleanup_failed exn ->
     failf "cancellation was reported as an ordinary failure: %s" (Printexc.to_string exn));
  match
    Supervisor_launch.run_cleanup_best_effort (fun () -> raise Synthetic_cleanup_failure)
  with
  | Supervisor_launch.Cleanup_failed Synthetic_cleanup_failure -> ()
  | Supervisor_launch.Cleanup_failed exn ->
    failf "unexpected cleanup failure: %s" (Printexc.to_string exn)
  | Supervisor_launch.Cleanup_completed -> fail "ordinary failure was reported as completed"
  | Supervisor_launch.Cleanup_cancelled -> fail "ordinary failure was reported as cancellation"

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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
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
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config)
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
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config)
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
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config)
        }
      in
      sweep_and_recover_no_materialize ctx;
      check bool
        "terminal event alone does not unregister lane"
        true
        (Reg.is_registered ~base_path:config.base_path name);
      (match
         Lane.reject_before_start reg.lane ~reason:(Failure "synthetic joined lane")
       with
       | Ok () -> ()
       | Error error -> fail (Lane.start_error_to_string error));
      sweep_and_recover_no_materialize ctx;
      check bool
        "joined terminal lane is unregistered"
        false
        (Reg.is_registered ~base_path:config.base_path name))


let test_idle_duration_never_stops_keeper () =
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
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:50 ~last_restart_ts:0.0 ~crash_log:[];
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      sweep_and_recover_no_materialize ctx;
      check bool "idle duration does not request stop" false
        (Atomic.get reg.fiber_stop);
      check bool "idle duration does not synthesize wake" false
        (Atomic.get reg.fiber_wakeup);
      check bool "idle Keeper lane remains live" true
        (Option.is_none (Eio.Promise.peek reg.done_p));
      (match Reg.get ~base_path:config.base_path name with
      | Some updated ->
         check bool "idle duration does not create failure reason" true
           (Option.is_none updated.last_failure_reason);
         check bool "idle Keeper remains Running" true
           (updated.phase = KSM.Running)
       | None -> fail "registry entry missing after idle sweep"))

(* A crashed lane whose failure is not a stale observation still follows the
   ordinary restart path regardless of prior restart count. *)
let test_non_storm_crashed_restarts_normally () =
  with_restart_launch_noop @@ fun () ->
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
      let name = "non-storm-keeper" in
      write_keeper_toml config_dir ~name;
      let meta = make_meta name in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "ordinary crash");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:50 ~last_restart_ts:0.0 ~crash_log:[];
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
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
       | Error err -> fail ("read_meta failed: " ^ err));
      (match Reg.get ~base_path:config.base_path name with
       | Some entry ->
         check bool "many prior restarts do not make Dead" false (entry.phase = KSM.Dead)
       | None -> fail "registry entry missing after ordinary restart"))

(* Failure observations remain durable across lane unregister/restart without
   changing the Keeper's operator-controlled lifecycle state. *)
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
      let name = "failure-blocker-keeper" in
      let meta = make_meta name in
      let meta =
        {
          meta with
          runtime =
            {
              meta.runtime with
              last_blocker = Some (Keeper_meta_contract.blocker_info_of_class ~detail:"test-blocker" Keeper_meta_contract.Stale_turn_timeout);
            };
        }
      in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "observed failure");
      Reg.restore_supervisor_state ~base_path:config.base_path name
        ~restart_count:0 ~last_restart_ts:0.0 ~crash_log:[];
      Reg.set_failure_reason ~base_path:config.base_path name
        (Some (Reg.Stale_termination_storm { count = 5 }));
      let ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = supervisor_agent_name
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = Some (Eio.Stdenv.net env)
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config)
        }
      in
      sweep_and_recover_no_materialize ctx;
      
      (* Check if blocker is persisted *)
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some m) ->
           (match m.runtime.last_blocker with
            | Some b ->
                check string "meta.runtime.last_blocker" "test-blocker" b.detail;
                check bool "meta.runtime.last_blocker.klass" true (b.klass = Keeper_meta_contract.Stale_turn_timeout)
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
                check bool "meta.runtime.last_blocker.klass after unregister" true (b.klass = Keeper_meta_contract.Stale_turn_timeout)
            | None -> fail "expected blocker after unregister")
       | Ok None -> fail "meta missing after unregister"
       | Error err -> fail ("read_meta failed: " ^ err)))

let () =
  run "keeper_supervisor" [
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
      test_case "declarative boot preserves instructions" `Quick
        test_declarative_boot_materializes_instructions;
      test_case "declarative boot allows empty goal links" `Quick
        test_declarative_boot_allows_empty_goal_links;
      test_case "declarative boot records typed invalid-config failure" `Quick
        test_declarative_boot_records_typed_invalid_config_failure;
      test_case "reconcile materializes configured keeper without meta" `Quick
        test_reconcile_materializes_configured_keeper_without_meta;
      test_case "reconcile does not double-start materialized keeper" `Quick
        test_reconcile_does_not_double_start_materialized_keeper;
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
    ];
    "nonhierarchical_hitl_visibility", [
      test_case "pending HITL approval names include only persisted keepers" `Quick
        test_pending_hitl_approval_keeper_names_filters_persisted_pending;
      test_case "sweep does not synthesize a gate from runtime blockers" `Quick
        test_sweep_does_not_synthesize_gate_from_runtime_blocker;
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
      test_case "sweep cleanup fires Tombstone_reaped hook" `Quick
        test_sweep_and_recover_fires_tombstone_reaped_hook;
      test_case "failing Tombstone_reaped hook is swallowed" `Quick
        test_sweep_and_recover_swallows_failing_tombstone_hook;
    ];
    "stale_storm_phase2", [
      test_case "legacy Stale_fleet_batch follows restart path" `Quick
        test_legacy_stale_fleet_batch_routes_to_restart;
      test_case "supervisor cleanup suppresses cancellation and classifies failures" `Quick
        test_supervisor_cleanup_suppresses_cancellation_and_classifies_failures;
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
      test_case "idle duration never stops keeper" `Quick
        test_idle_duration_never_stops_keeper;
      test_case "non-storm Crashed still routes to restart (regression guard)" `Quick
        test_non_storm_crashed_restarts_normally;
    ];
    "failure_observation", [
      test_case "persisted blocker survives unregister" `Quick
        test_persisted_blocker_survives_unregister;
    ];
  ]
