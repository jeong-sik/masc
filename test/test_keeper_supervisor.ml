(** Test suite for Keeper_supervisor — fiber liveness tracking and recovery.
    Pure tests for backoff/helpers. Fiber health queries now delegate to
    Keeper_registry (tested in test_keeper_registry.ml). *)

open Alcotest
module Sup = Masc.Keeper_supervisor
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module Keeper_types_profile = Masc.Keeper_types_profile
module Keeper_owner_registry = Masc.Keeper_owner_registry
module Workspace = Masc.Workspace
module Reg = Masc.Keeper_registry
module KT = Keeper_types
module KR = Masc.Keeper_runtime
module AQ = Masc.Keeper_approval_queue
module AQT = Keeper_approval_queue_rules_types
module KSM = Keeper_state_machine
module KLH = Masc.Keeper_lifecycle_hooks
module KA = Masc.Keeper_keepalive
module KSR = Masc.Keeper_supervisor_reconcile_keepalive
module KSS = Masc.Keeper_supervisor_supervise_keepalive
module Chat_operation = Masc.Keeper_owner.Chat_operation
module Supervisor_launch = Masc.Keeper_supervisor_launch
module Lane = Masc.Keeper_lane
module Memory_lane = Masc.Keeper_memory_lane
module Shutdown_finalize = Masc.Keeper_shutdown_finalize
module Shutdown_store = Masc.Keeper_shutdown_store
module Shutdown_types = Masc.Keeper_shutdown_types
module Subprocess_registry = Masc.Keeper_subprocess_registry
module Supervisor_cleanup = Masc.Keeper_supervisor_cleanup
module Process_switch = Masc.Keeper_process_switch
module Tool_accumulator = Masc.Keeper_tool_emission_hook
module Latched_reason = Keeper_latched_reason
module Lifecycle_reservation = Masc.Keeper_lifecycle_reservation
module Launch_transaction = Masc.Keeper_keepalive_launch_transaction

(* Test-local shim for the excised [Keeper_approval_queue.resolve] wrapper:
   unit projection over [resolve_with_policy] (production resolution path). *)
let aq_resolve ~base_path ~id ~decision =
  match AQ.resolve_with_policy ~base_path ~id ~decision () with
  | Ok _ -> Ok ()
  | Error _ as error -> error
;;

let supervisor_agent_name = Sup.supervisor_agent_name

let with_launch_token ~base_path ~keeper_name f =
  match
    Lifecycle_reservation.acquire
      ~base_path
      ~keeper_name
      ~purpose:Lifecycle_reservation.Keepalive_launch
  with
  | Error (Lifecycle_reservation.Already_reserved owner) ->
    fail
      ("launch lifecycle already reserved: "
       ^ Lifecycle_reservation.snapshot_to_string owner)
  | Ok token ->
    Fun.protect
      ~finally:(fun () ->
        ignore
          (Lifecycle_reservation.release token
            : Lifecycle_reservation.release_outcome))
      (fun () -> f token)

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

let install_exn ~base_path =
  match AQ.install_persistence ~base_path with
  | Ok report -> report
  | Error error -> fail (AQ.install_error_to_string error)

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

let install_owner_inventory_exn ~sw config =
  match
    Keeper_owner_registry.install_from_store
      ~sw
      ~operation_runner:None
      ~on_turn_slot_released:None
      config
  with
  | Ok _ -> ()
  | Error error ->
    fail (Keeper_owner_registry.install_error_to_string error)
;;

let create_owner_meta_exn config meta =
  match
    Keeper_owner_registry.create_meta
      ~base_path:config.Workspace.base_path
      meta
  with
  | Ok (Some _) -> ()
  | Ok None -> fail "owner metadata creation removed its snapshot"
  | Error error ->
    fail (Keeper_owner_registry.command_error_to_string error)
;;

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
  let profile_dir = Filename.concat (Filename.concat config_dir "keepers") name in
  mkdir_p profile_dir;
  write_file
    (Filename.concat (Filename.concat config_dir "keepers") (name ^ ".toml"))
    (Printf.sprintf
       {|
[keeper]
name = "%s"
instructions = "test keeper"
sandbox_profile = "docker"
|}
       name)

let write_keeper_toml_with_instructions config_dir ~name ~instructions =
  let profile_dir = Filename.concat (Filename.concat config_dir "keepers") name in
  mkdir_p profile_dir;
  write_file
    (Filename.concat (Filename.concat config_dir "keepers") (name ^ ".toml"))
    (Printf.sprintf
       {|
[keeper]
name = "%s"
sandbox_profile = "docker"
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
instructions = "test keeper"
sandbox_profile = "docker"
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
  Reg.For_testing.clear ();
  let health = Reg.fiber_health_of ~base_path:"/tmp" "nonexistent-keeper" in
  check bool "unknown for unregistered"
    true (health = KT.Fiber_unknown)

let test_registry_count_initially_zero () =
  Reg.For_testing.clear ();
  check int "no keepers initially" 0 (Reg.count_running ())

let test_crash_log_empty_for_unknown () =
  Reg.For_testing.clear ();
  check int "empty crash log" 0
    (List.length (Reg.For_testing.crash_log_of ~base_path:"/tmp" "nonexistent"))

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
(* sandbox_profile and network_mode left the meta JSON wire schema -- they
   arrive from keeper.toml now, and meta_of_json rejects a document that still
   carries them ("fields outside the current schema ... runtime reset
   required"). This fixture only ever set them to the record defaults
   ("local" / "inherit"), so dropping them changes nothing these cases assert.
   test_keeper_keepalive_helpers made the same edit; this suite was outside CI,
   so its copy kept the old shape (#28131). *)
let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ ("name", `String name)
        ; ("trace_id", `String ("trace-" ^ name))
        ])
  with
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
       ~agent_name:meta.name
       ~task_id:created.task_id
       ()
   with
   | Ok _ -> ()
   | Error err -> fail (Masc_domain.masc_error_to_string err));
  (match
     Masc.Workspace.transition_task_r
       config
       ~agent_name:meta.name
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
            (aq_resolve
               ~base_path:base_dir
               ~id
               ~decision:(AQT.Decision.Reject "test cleanup")))
        !approval_ids;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _workspace =
        Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name)
      in
      ignore (install_exn ~base_path:config.base_path);
      let blocked = make_meta "hitl-blocked" in
      let clear = make_meta "hitl-clear" in
      List.iter
        (fun meta ->
          match Keeper_meta_store.replace_snapshot config meta with
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
          | Ok submission -> submission.approval_id
          | Error error -> fail (AQ.storage_error_to_string error)
        in
        approval_ids := id :: !approval_ids
      in
      submit blocked.name;
      submit "not-persisted";
      check (list string) "only persisted pending keeper is surfaced"
        [ blocked.name ]
        (match Sup.pending_hitl_approval_keeper_names config with
         | Ok names -> names
         | Error error -> fail (AQ.storage_error_to_string error)))

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
      Reg.For_testing.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  install_owner_inventory_exn ~sw config;
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
      Reg.For_testing.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  install_owner_inventory_exn ~sw config;
  let ctx = keeper_runtime_context env sw config in
  Fun.protect
    ~finally:(fun () -> KR.stop_keepalive ~base_path:config.base_path name)
    (fun () ->
      (match KR.load_or_materialize_boot_meta ctx name with
       | Error err -> fail err
       | Ok resolution ->
         check bool "empty-goal keeper materialized" true resolution.materialized;
         ());
      check bool "no boot failure recorded" true
        (Option.is_none (KR.boot_meta_failure_for ~base_path:config.base_path ~name)))

(* #29610: a persisted meta this binary cannot decode reads as absent. The
   reader says so once at WARN, declarative startup proceeds as for a missing
   meta, and the TOML declaration re-materialises the keeper. The unreadable
   file is parked as a .rejected-* sibling before the materialized snapshot
   takes its path: the counters leave service, but the only copy is no longer
   destroyed (2026-08-29, nine keepers zeroed by a schema cut). *)
let test_declarative_boot_rematerializes_incompatible_meta () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  let name = "incompatible-meta" in
  write_keeper_toml config_dir ~name;
  Eio.Switch.on_release sw (fun () ->
      Reg.For_testing.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  install_owner_inventory_exn ~sw config;
  let ctx = keeper_runtime_context env sw config in
  let meta_path = Keeper_types_profile.keeper_meta_path config name in
  let base_meta = make_meta name in
  let accumulated =
    {
      base_meta with
      runtime =
        {
          base_meta.runtime with
          usage = { base_meta.runtime.usage with total_turns = 7 };
        };
    }
  in
  (match Keeper_meta_store.replace_snapshot config accumulated with
   | Ok () -> ()
   | Error err -> fail err);
  let incompatible_json =
    match Yojson.Safe.from_file meta_path with
    | `Assoc fields -> `Assoc (fields @ [ "goal", `String "removed" ])
    | _ -> fail "keeper meta fixture must be a JSON object"
  in
  Fs_compat.save_file meta_path (Yojson.Safe.to_string incompatible_json);
  let bytes_before = Fs_compat.load_file meta_path in
  let baseline = latest_log_seq () in
  (match Keeper_meta_store.read_meta config name with
   | Ok None -> ()
   | Ok (Some _) -> fail "incompatible meta was served as a keeper"
   | Error err ->
     fail ("incompatible meta was refused instead of read as absent: " ^ err));
  Fun.protect
    ~finally:(fun () -> KR.stop_keepalive ~base_path:config.base_path name)
    (fun () ->
      let resolution =
        match KR.load_or_materialize_boot_meta ctx name with
        | Error err -> fail err
        | Ok resolution -> resolution
      in
      check bool "incompatible meta is re-materialized from the declaration"
        true resolution.materialized;
      check string "materialized meta carries the declaration's instructions"
        "test keeper" resolution.meta.instructions;
      check int "accumulated counters in the unreadable meta are lost" 0
        resolution.meta.runtime.usage.total_turns;
      let keeper_entries =
        Log.Ring.recent
          ~limit:1000
          ~module_filter:"Keeper"
          ~since_seq:baseline
          ~order:`Oldest_first
          ()
      in
      let count_exact level message =
        keeper_entries
        |> List.filter (fun (entry : Log.Ring.entry) ->
             entry.level = level && String.equal entry.message message)
        |> List.length
      in
      let expected_warn =
        Printf.sprintf
          "keeper meta unreadable at %s, treating as absent (accumulated \
           counters in it are lost; the declaration re-materialises the \
           keeper): invalid current keeper meta: fields outside the current \
           schema: goal; runtime reset required"
          meta_path
      in
      check int "the loss is named once, in the reader's WARN" 1
        (count_exact Log.Warn expected_warn);
      (* Parking empties the path before keeper_up rewrites it, so the
         reader's problem record clears on the not-exists branch and no
         "parse recovered" INFO follows; the parking WARN is the line that
         closes the episode. *)
      let count_prefix level prefix =
        keeper_entries
        |> List.filter (fun (entry : Log.Ring.entry) ->
             entry.level = level
             && String.starts_with ~prefix entry.message)
        |> List.length
      in
      check int "the parking WARN closes the episode once" 1
        (count_prefix Log.Warn
           (Printf.sprintf "parked unreadable keeper meta %s" meta_path));
      check int "no parse-recovered INFO remains for the emptied path" 0
        (count_exact Log.Info
           (Printf.sprintf "keeper meta parse recovered for %s" meta_path));
      check bool "the materialized snapshot replaces the unreadable file" false
        (String.equal bytes_before (Fs_compat.load_file meta_path));
      let parked =
        Sys.readdir (Filename.dirname meta_path)
        |> Array.to_list
        |> List.filter (fun f ->
             String.starts_with
               ~prefix:(Filename.basename meta_path ^ ".rejected-")
               f)
      in
      check int "the unreadable file is parked exactly once" 1
        (List.length parked);
      (match parked with
       | [ parked_name ] ->
         check string "the parked file preserves the unreadable bytes"
           bytes_before
           (Fs_compat.load_file
              (Filename.concat (Filename.dirname meta_path) parked_name))
       | _ -> ());
      (match Keeper_meta_store.read_meta config name with
       | Ok (Some persisted) ->
         let trace_id = Keeper_id.Trace_id.to_string persisted.runtime.trace_id in
         check string "the persisted snapshot is the materialized keeper"
           (Keeper_id.Trace_id.to_string resolution.meta.runtime.trace_id)
           trace_id;
         check bool "the fixture's trace id did not survive the replacement"
           false
           (String.equal trace_id ("trace-" ^ name))
       | Ok None -> fail "materialized meta was not persisted"
       | Error err -> fail err);
      check bool "no boot failure recorded" true
        (Option.is_none
           (KR.boot_meta_failure_for ~base_path:config.base_path ~name)))

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
      Reg.For_testing.clear ();
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
      Reg.For_testing.clear ();
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
      Reg.For_testing.clear ();
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
      Reg.For_testing.clear ();
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
  (match Keeper_meta_store.replace_snapshot config meta with
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
     check string "manual pause keeps active owner" base_meta.name assignee
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
      Reg.For_testing.clear ();
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
      Reg.For_testing.clear ();
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

let test_supervise_keepalive_retains_sweep_owned_entries () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = Filename.dirname config_dir in
  Eio.Switch.on_release sw (fun () ->
      Reg.For_testing.clear ();
      KR.reset_test_state base_dir);
  let config = Masc.Workspace.default_config base_dir in
  let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
  let ctx = keeper_runtime_context env sw config in
  let launched = ref [] in
  let publish_lifecycle ~event:_ _name _detail () = () in
  let launch_supervised_fiber
        ~intake_token:_
        ~lifecycle_token:_
        ~proactive_warmup_sec:_
        _ctx
        _meta
        (entry : Reg.registry_entry)
    =
    launched := (entry.name, entry.phase) :: !launched;
    Ok ()
  in
  let stopped_name = "recoverable-stopped-owner" in
  let stopped_meta = make_meta stopped_name in
  let stopped =
    Reg.For_testing.register ~base_path:config.base_path stopped_name stopped_meta
  in
  ignore
    (Reg.dispatch_event ~base_path:config.base_path stopped_name KSM.Stop_requested);
  (match
     Reg.dispatch_event ~base_path:config.base_path stopped_name KSM.Drain_complete
   with
   | Ok transition ->
     check
       string
       "stopped fixture phase"
       "stopped"
       (KSM.phase_to_string transition.new_phase)
   | Error error -> fail (KSM.transition_error_to_string error));
  ignore (Reg.resolve_done stopped ~source:"stopped_owner_fixture" `Stopped);
  KSS.supervise_keepalive
    ~publish_lifecycle
    ~launch_supervised_fiber
    ~proactive_warmup_sec:0
    ctx
    stopped_meta;
  let crashed_name = "recoverable-crashed-owner" in
  let crashed_meta = make_meta crashed_name in
  let _crashed =
    Reg.For_testing.register ~base_path:config.base_path crashed_name crashed_meta
  in
  (match
     Reg.dispatch_event
       ~base_path:config.base_path
       crashed_name
       (KSM.Fiber_terminated
          { outcome = "fixture crash"; provider_id = None; http_status = None })
   with
   | Ok transition ->
     check
       string
       "crashed fixture phase"
       "crashed"
       (KSM.phase_to_string transition.new_phase)
   | Error error -> fail (KSM.transition_error_to_string error));
  KSS.supervise_keepalive
    ~publish_lifecycle
    ~launch_supervised_fiber
    ~proactive_warmup_sec:0
    ctx
    crashed_meta;
  check
    (list (pair string string))
    "Stopped and Crashed owners remain assigned to the supervisor sweep"
    []
    (List.rev_map
       (fun (name, phase) -> name, KSM.phase_to_string phase)
       !launched)

let test_supervise_recovery_requires_same_offline_generation () =
  with_config_dir @@ fun config_dir ->
  Eio_main.run @@ fun _env ->
  let base_dir = Filename.dirname config_dir in
  Fun.protect
    ~finally:(fun () -> Reg.For_testing.clear ())
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg =
        Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name)
      in
      let name = "recoverable-offline-generation" in
      let entry =
        Reg.register_offline ~base_path:config.base_path name (make_meta name)
      in
      check bool "same Offline generation remains launchable" true
        (KSS.For_testing.same_offline_generation ~expected:entry entry);
      (match Reg.dispatch_event_exact entry KSM.Fiber_started with
       | Ok _ -> ()
       | Error error -> fail (KSM.transition_error_to_string error));
      match Reg.get ~base_path:config.base_path name with
      | None -> fail "generation fixture disappeared"
      | Some running ->
        check bool "advanced generation cannot be launched again" false
          (KSS.For_testing.same_offline_generation ~expected:entry running))

let test_supervise_keepalive_wakes_ready_operation_drain () =
  Eio_main.run @@ fun env ->
  ensure_test_runtime ();
  ensure_fs env;
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      KR.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       let clock = Eio.Stdenv.clock env in
       let config = Masc.Workspace.default_config base_dir in
       let _init_msg =
         Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name)
       in
       let name = "supervised-operation-ready" in
       let meta = make_meta name in
       (match Keeper_meta_store.replace_snapshot config meta with
        | Ok () -> ()
        | Error detail -> fail ("failed to seed owner meta: " ^ detail));
       let runner_ready = Atomic.make false in
       let execution_count = ref 0 in
       let executor_started, resolve_executor_started = Eio.Promise.create () in
       let release_executor, resolve_release_executor = Eio.Promise.create () in
       let operation_runner : Masc.Keeper_owner.operation_runner =
         { ready =
             (fun ~keeper_name ->
                String.equal keeper_name name && Atomic.get runner_ready)
         ; execute =
             (fun ~sw:_ ~keeper_name ~claim ->
                check string "executor keeper" name keeper_name;
                incr execution_count;
                match claim () with
                | Error error ->
                  fail (Masc.Keeper_owner.error_to_string error)
                | Ok None -> fail "ready wake started an executor without a queued operation"
                | Ok (Some operation) ->
                  Eio.Promise.resolve resolve_executor_started operation.operation_id;
                  Eio.Promise.await release_executor;
                  Masc.Keeper_owner.Operation_succeeded
                    { outcome_ref = "supervisor-ready-wake" })
         ; on_execution_settled =
             (fun ~keeper_name:_ ~claimed_operation_id:_ ~execution:_ -> ())
         }
       in
       (match
          Masc.Keeper_owner_registry.install_from_store
            ~sw
            ~operation_runner:(Some operation_runner)
            ~on_turn_slot_released:None
            config
        with
        | Ok 1 -> ()
        | Ok count -> failf "expected one owner, got %d" count
        | Error error ->
          fail (Masc.Keeper_owner_registry.install_error_to_string error));
       let operation_id =
         match Chat_operation.Operation_id.of_string "kmsg-supervisor-ready-wake" with
         | Ok operation_id -> operation_id
         | Error detail -> fail detail
       in
       let accepted =
         match
           Masc.Keeper_owner_registry.submit_operation
             ~base_path:config.base_path
             ~keeper_name:name
             ~operation_id
             ~source:(`Assoc [ "kind", `String "test" ])
             ~input:(`Assoc [ "message", `String "wait for supervised readiness" ])
         with
         | Ok accepted -> accepted
         | Error error ->
           fail (Masc.Keeper_owner_registry.command_error_to_string error)
       in
       (match accepted.operation.state with
        | Chat_operation.Queued -> ()
        | state ->
          fail
            ("unready runner did not preserve Queued: "
             ^ Chat_operation.state_to_string state));
       Eio.Fiber.yield ();
       check int "unready runner starts no operation child" 0 !execution_count;
       let ctx = keeper_runtime_context env sw config in
       let publish_lifecycle ~event:_ _name _detail () = () in
       let launch_supervised_fiber
             ~intake_token:_
             ~lifecycle_token:_
             ~proactive_warmup_sec:_
             _ctx
             _meta
             (_entry : Reg.registry_entry)
         =
         Atomic.set runner_ready true;
         Ok ()
       in
       KSS.supervise_keepalive
         ~publish_lifecycle
         ~launch_supervised_fiber
         ~proactive_warmup_sec:0
         ctx
         meta;
       let executor_started_in_time =
         wait_until
           ~clock
           ~deadline:(Eio.Time.now clock +. 1.0)
           (fun () -> Option.is_some (Eio.Promise.peek executor_started))
       in
       check
         bool
         "supervisor wake starts the queued operation before timeout"
         true
         executor_started_in_time;
       let claimed_operation_id = Eio.Promise.await executor_started in
       check
         string
         "supervisor wake claims the queued operation"
         (Chat_operation.Operation_id.to_string operation_id)
         (Chat_operation.Operation_id.to_string claimed_operation_id);
       check int "supervisor wake starts exactly one operation child" 1 !execution_count;
       (match
          Masc.Keeper_owner_registry.run_autonomous_if_idle
            ~base_path:config.base_path
            ~keeper_name:name
            (fun () -> ())
        with
        | Ok (`Busy _) -> ()
        | Ok (`Ran ()) -> fail "autonomous work overtook the ready operation drain"
       | Error error ->
          fail (Masc.Keeper_owner_registry.command_error_to_string error));
       Eio.Promise.resolve resolve_release_executor ();
       let completed =
         wait_until
           ~clock
           ~deadline:(Eio.Time.now clock +. 1.0)
           (fun () ->
              match
                Masc.Keeper_owner_registry.exact_operation
                  ~base_path:config.base_path
                  ~keeper_name:name
                  operation_id
              with
              | Ok (Some operation) -> Chat_operation.is_terminal operation.state
              | Ok None
              | Error _ -> false)
       in
       check bool "supervisor-woken operation reaches terminal state" true completed;
       Eio.Fiber.yield ();
       check int "completed drain was not duplicated" 1 !execution_count)

let registered_entries names =
  Reg.For_testing.clear ();
  List.map
    (fun name -> Reg.For_testing.register ~base_path:bp name (make_meta name))
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
  Reg.For_testing.unregister ~base_path:bp "alpha";
  Reg.For_testing.unregister ~base_path:bp "bravo";
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
      Reg.For_testing.clear ();
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
        }
      in
      (match Keeper_meta_store.replace_snapshot config meta with
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
      let pending_before =
        AQ.list_pending_entries_for_workspace ~base_path:config.base_path
        |> Result.get_ok
        |> List.length
      in
      sweep_and_recover_no_materialize ctx;
      check bool "paused keeper has no synthetic approval" false
        (AQ.pending_count_for_keeper_in_workspace
           ~base_path:config.base_path
           ~keeper_name:meta.name
         |> Result.get_ok
         |> fun count -> count > 0);
      check int "approval count unchanged" pending_before
        (AQ.list_pending_entries_for_workspace ~base_path:config.base_path
         |> Result.get_ok
         |> List.length);
      let persisted_meta =
        match Keeper_meta_store.read_meta config meta.name with
        | Ok (Some value) -> value
        | Ok None -> fail "expected persisted keeper meta"
        | Error err -> fail err
      in
      check bool "sweep does not reinterpret pause" true persisted_meta.paused)

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
             (aq_resolve
                ~base_path:base_dir
                ~id
                ~decision:(AQT.Decision.Reject "test cleanup")))
        !approval_id;
      Reg.For_testing.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      Log.set_level Log.Info;
      let config = Masc.Workspace.default_config base_dir in
      let _workspace = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      ignore (install_exn ~base_path:config.base_path);
      let meta = make_meta name in
      (match Keeper_meta_store.replace_snapshot config meta with
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
        | Ok submission -> submission.approval_id
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
        (AQ.pending_count_for_keeper_in_workspace
           ~base_path:base_dir
           ~keeper_name:name
         |> Result.get_ok
         |> fun count -> count > 0);
      (match aq_resolve ~base_path:base_dir ~id ~decision:AQT.Decision.Approve with
       | Ok () -> approval_id := None
       | Error err -> fail ("resolve failed: " ^ AQ.resolve_error_to_string err));
      check bool "resolution removes pending request" false
        (AQ.pending_count_for_keeper_in_workspace
           ~base_path:base_dir
           ~keeper_name:name
         |> Result.get_ok
         |> fun count -> count > 0))

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
      Reg.For_testing.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      write_keeper_toml config_dir ~name;
      let meta = make_meta name in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.For_testing.register ~base_path:config.base_path name meta in
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

let test_restart_reopens_crash_aborted_librarian_lifecycle () =
  with_restart_launch_noop @@ fun () ->
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_config_dir @@ fun config_dir ->
  let base_dir = temp_dir () in
  let name = "restart-reopens-librarian" in
  Fun.protect
    ~finally:(fun () ->
      Memory_lane.For_testing.reset ();
      Reg.For_testing.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      Memory_lane.For_testing.reset ();
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
      write_keeper_toml config_dir ~name;
      let meta = make_meta name in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.For_testing.register ~base_path:config.base_path name meta in
      resolve_done_for_test reg (`Crashed "ordinary crash");
      (match Memory_lane.abort_librarian ~base_path:config.base_path ~keeper_name:name with
       | Ok Memory_lane.Librarian_abort_idle -> ()
       | Ok _ -> fail "empty crash-abort fixture unexpectedly owned Librarian work"
       | Error error -> fail (Memory_lane.librarian_abort_error_to_string error));
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
      (match Reg.get ~base_path:config.base_path name with
       | Some entry ->
         check bool "supervisor published replacement registry lane" true
           (entry.done_p != reg.done_p)
       | None -> fail "supervisor restart removed the Keeper registry entry");
      match Memory_lane.submit ~base_path:config.base_path ~keeper_name:name (fun () -> ()) with
      | Memory_lane.Ran_inline -> ()
      | Memory_lane.Submitted | Memory_lane.Coalesced -> ()
      | Memory_lane.Dropped -> fail "restarted Librarian submission was dropped"
      | Memory_lane.Rejected_draining ->
        fail "supervisor restart left the Librarian lifecycle fenced")
;;

let test_restart_path_emits_meta_unavailable_outcome_metric () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let name = "restart-missing-meta-metric-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let meta = make_meta name in
      let reg = Reg.For_testing.register ~base_path:config.base_path name meta in
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
let test_supervised_stop_joins_board_attention_worker () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
      let name = "supervised-board-worker-stop" in
      let meta = make_meta name in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.register_offline ~base_path:config.base_path name meta in
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
      with_launch_token
        ~base_path:config.base_path
        ~keeper_name:name
        (fun lifecycle_token ->
           match
             Masc.Keeper_supervisor_launch.launch_supervised_fiber
               ~lifecycle_token
               ~proactive_warmup_sec:0
               ctx
               meta
               reg
           with
           | Ok () -> ()
           | Error error ->
             fail (Keeper_state_machine.transition_error_to_string error));
      let joined =
        Eio.Time.with_timeout_exn ctx.clock 5.0 (fun () ->
          Masc.Keeper_keepalive.stop_keepalive_and_await
            ~base_path:config.base_path
            name)
      in
      (match joined with
       | Masc.Keeper_keepalive.Keeper_not_registered ->
         fail "supervised Keeper disappeared before joined stop"
       | Masc.Keeper_keepalive.Keeper_joined { terminal = `Stopped; _ } -> ()
       | Masc.Keeper_keepalive.Keeper_joined { terminal = `Crashed reason; _ } ->
         fail ("supervised stop resolved as crashed: " ^ reason));
      check bool
        "board-attention sibling joined with supervised lane"
        true
        (Reg.lane_has_exited reg))

let test_supervised_stop_drains_librarian_before_terminal () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Memory_lane.For_testing.reset ();
      Reg.For_testing.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
      let name = "supervised-librarian-drain" in
      let meta = make_meta name in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error err -> fail err);
      Memory_lane.init ~sw;
      (match
         Memory_lane.begin_librarian_lifecycle
           ~base_path:config.base_path
           ~keeper_name:name
       with
       | Ok () -> ()
       | Error error -> fail (Memory_lane.lifecycle_open_error_to_string error));
      let reg = Reg.register_offline ~base_path:config.base_path name meta in
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
      with_launch_token
        ~base_path:config.base_path
        ~keeper_name:name
        (fun lifecycle_token ->
           match
             Masc.Keeper_supervisor_launch.launch_supervised_fiber
               ~lifecycle_token
               ~proactive_warmup_sec:0
               ctx
               meta
               reg
           with
           | Ok () -> ()
           | Error error -> fail (Keeper_state_machine.transition_error_to_string error));
      let librarian_started, resolve_librarian_started = Eio.Promise.create () in
      let librarian_release, resolve_librarian_release = Eio.Promise.create () in
      let librarian_cancelled = ref false in
      let librarian_completed = ref false in
      (match
         Memory_lane.submit
           ~base_path:config.base_path
           ~keeper_name:name
           (fun () ->
              Eio.Promise.resolve resolve_librarian_started ();
              try
                Eio.Promise.await librarian_release;
                librarian_completed := true
              with
              | Eio.Cancel.Cancelled _ as exn ->
                librarian_cancelled := true;
                raise exn)
       with
       | Memory_lane.Submitted
       | Memory_lane.Coalesced -> ()
       | Memory_lane.Ran_inline
       | Memory_lane.Dropped
       | Memory_lane.Rejected_draining ->
         fail "supervised Librarian fixture was not submitted");
      Eio.Promise.await librarian_started;
      let stop_done, resolve_stop_done = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve
          resolve_stop_done
          (Masc.Keeper_keepalive.stop_keepalive_and_await
             ~base_path:config.base_path
             name));
      Eio.Time.sleep ctx.clock 0.05;
      check bool
        "supervised stop waits for accepted Librarian work"
        true
        (Option.is_none (Eio.Promise.peek stop_done));
      check bool
        "terminal promise stays pending until Librarian drain"
        true
        (Option.is_none (Eio.Promise.peek reg.done_p));
      Eio.Promise.resolve resolve_librarian_release ();
      let joined = Eio.Promise.await stop_done in
      (match joined with
       | Masc.Keeper_keepalive.Keeper_not_registered ->
         fail "supervised Keeper disappeared before Librarian join"
       | Masc.Keeper_keepalive.Keeper_joined
           { lane_exit = { cleanup_error = None; _ }; terminal = `Stopped } -> ()
       | Masc.Keeper_keepalive.Keeper_joined
           { lane_exit = { cleanup_error = Some error; _ }; _ } ->
         fail ("supervised Librarian cleanup failed: " ^ error)
       | Masc.Keeper_keepalive.Keeper_joined { terminal = `Crashed reason; _ } ->
         fail ("supervised Librarian stop resolved as crashed: " ^ reason));
      check bool
        "supervised stop preserves Librarian work"
        false
        !librarian_cancelled;
      check bool
        "supervised stop drains Librarian before terminal"
        true
        !librarian_completed;
      check
        (option int)
        "supervised Librarian has no pending work after stop"
        (Some 0)
        (Memory_lane.For_testing.pending
           ~base_path:config.base_path
           ~keeper_name:name))

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
      Reg.For_testing.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg =
        Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name)
      in
      let name = "launch-fork-reject" in
      let meta = make_meta name in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.For_testing.register ~base_path:config.base_path name meta in
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
      with_launch_token
        ~base_path:config.base_path
        ~keeper_name:name
        (fun lifecycle_token ->
           match
             Masc.Keeper_supervisor_launch.launch_supervised_fiber
               ~lifecycle_token
               ~proactive_warmup_sec:0
               ctx
               meta
               reg
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
      Reg.For_testing.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
      let name = "fork-reject-replacement" in
      let meta = make_meta name in
      let rejected = Reg.For_testing.register ~base_path:config.base_path name meta in
      (match
         Lane.reject_before_start rejected.lane ~reason:(Failure "pre-claimed for test")
       with
       | Ok () -> ()
       | Error error -> fail (Lane.start_error_to_string error));
      let replacement = Reg.For_testing.register ~base_path:config.base_path name meta in
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
      with_launch_token
        ~base_path:config.base_path
        ~keeper_name:name
        (fun lifecycle_token ->
           match
             Masc.Keeper_supervisor_launch.launch_supervised_fiber_body
               ~lifecycle_token
               ~proactive_warmup_sec:0
               ctx
               meta
               rejected
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

let test_sweep_waits_for_lane_join_before_unregister () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
      let name = "joined-before-unregister" in
      let meta = make_meta name in
      let reg = Reg.For_testing.register ~base_path:config.base_path name meta in
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
      Reg.For_testing.clear ();
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
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.For_testing.register ~base_path:config.base_path name meta in
      Reg.For_testing.set_started_at_for_test
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
      Reg.For_testing.clear ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let _init_msg = Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name) in
      let name = "non-storm-keeper" in
      write_keeper_toml config_dir ~name;
      let meta = make_meta name in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error err -> fail err);
      let reg = Reg.For_testing.register ~base_path:config.base_path name meta in
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
       | Some _ -> ()
       | None -> fail "registry entry missing after ordinary restart"))

(* Failure observations remain durable across lane unregister/restart without
   changing the Keeper's operator-controlled lifecycle state. *)
let test_active_librarian_abort_defers_then_retries_restart () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Memory_lane.For_testing.reset ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
       Memory_lane.For_testing.reset ();
       Memory_lane.init ~sw;
       let name = "librarian-restart-rollback" in
       let meta = make_meta name in
       let initial = Reg.For_testing.register ~base_path:config.base_path name meta in
       (match
          Reg.dispatch_event_exact
            initial
            (KSM.Fiber_terminated
               { outcome = "fixture crash"; provider_id = None; http_status = None })
        with
        | Ok _ -> ()
        | Error error -> fail (KSM.transition_error_to_string error));
       let crashed =
         match Reg.get ~base_path:config.base_path name with
         | Some entry -> entry
         | None -> fail "crashed restart fixture disappeared"
       in
       let started, set_started = Eio.Promise.create () in
       let cancellation_seen, set_cancellation_seen = Eio.Promise.create () in
       let release_cleanup, set_release_cleanup = Eio.Promise.create () in
       let never, _set_never = Eio.Promise.create () in
       (match
          Memory_lane.submit ~base_path:config.base_path ~keeper_name:name (fun () ->
            Eio.Promise.resolve set_started ();
            try Eio.Promise.await never with
            | Eio.Cancel.Cancelled _ as exn ->
              Eio.Promise.resolve set_cancellation_seen ();
              Eio.Cancel.protect (fun () -> Eio.Promise.await release_cleanup);
              raise exn)
        with
        | Memory_lane.Submitted -> ()
        | Memory_lane.Coalesced
        | Memory_lane.Ran_inline
        | Memory_lane.Dropped
        | Memory_lane.Rejected_draining -> fail "active Librarian fixture was not submitted");
       Eio.Promise.await started;
       (match Memory_lane.abort_librarian ~base_path:config.base_path ~keeper_name:name with
        | Ok Memory_lane.Librarian_abort_requested
        | Ok Memory_lane.Librarian_abort_already_in_progress -> ()
        | Ok _ -> fail "active Librarian abort did not commit cancellation"
        | Error error -> fail (Memory_lane.librarian_abort_error_to_string error));
       Eio.Promise.await cancellation_seen;
       let run_restart (previous : Reg.registry_entry) =
         Launch_transaction.run
           ~base_path:config.base_path
           ~keeper_name:name
           ~register:(fun token intake_token ->
             Reg.register_restarting_for_lifecycle
               ~intake_token
               token
               ~base_path:config.base_path
               name
               meta)
           ~rollback:(Launch_transaction.Restore_previous previous)
           (fun _intake_token _token replacement -> replacement)
       in
       (match run_restart crashed with
        | Error (Launch_transaction.Lifecycle_open_failed _) -> ()
        | Error _ -> fail "restart deferred for an unexpected transaction reason"
        | Ok _ -> fail "restart crossed an active cancelled Librarian owner");
       (match Reg.get ~base_path:config.base_path name with
        | Some current ->
          check bool "deferred restart restores the crashed lane" true
            (Lane.Id.equal (Lane.id current.lane) (Lane.id crashed.lane))
        | None -> fail "deferred restart lost its durable crashed authority");
       Eio.Promise.resolve set_release_cleanup ();
       (match
          Memory_lane.drain_and_join_librarian
            ~base_path:config.base_path
            ~keeper_name:name
        with
        | Error (Memory_lane.Librarian_interrupted _) -> ()
        | Error error -> fail (Memory_lane.librarian_drain_error_to_string error)
        | Ok _ -> fail "cancelled Librarian was reported as gracefully drained");
       let replacement =
         match run_restart crashed with
         | Ok replacement -> replacement
         | Error _ -> fail "next restart sweep did not reopen the exited Librarian owner"
       in
       check bool "retry installs a distinct restart lane" false
         (Lane.Id.equal (Lane.id replacement.lane) (Lane.id crashed.lane));
       ignore
         (Memory_lane.drain_and_join_librarian
            ~base_path:config.base_path
            ~keeper_name:name
           : (Memory_lane.librarian_drain_outcome,
              Memory_lane.librarian_drain_error)
               result))

let test_unexpected_cleanup_cannot_close_reopened_librarian_lifecycle () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Memory_lane.For_testing.reset ();
      cleanup_dir base_dir)
    (fun () ->
       Memory_lane.For_testing.reset ();
       let keeper_name = "unexpected-librarian-reopen" in
       (match
          Memory_lane.begin_librarian_lifecycle
            ~base_path:base_dir
            ~keeper_name
        with
        | Ok () -> ()
        | Error error -> fail (Memory_lane.lifecycle_open_error_to_string error));
       let replacement_opened = ref false in
       (match
          Launch_transaction.finish_lifecycle
            ~boundary:Launch_transaction.Unexpected
            ~base_path:base_dir
            ~keeper_name
            ~terminalize:(fun () ->
              match
                Memory_lane.begin_librarian_lifecycle
                  ~base_path:base_dir
                  ~keeper_name
              with
              | Ok () ->
                replacement_opened := true;
                Ok ()
              | Error error ->
                Error (Memory_lane.lifecycle_open_error_to_string error))
        with
        | Ok () -> ()
        | Error detail -> fail detail);
       check bool "terminal publication admitted replacement" true !replacement_opened;
       match Memory_lane.submit ~base_path:base_dir ~keeper_name ignore with
       | Memory_lane.Ran_inline -> ()
       | Memory_lane.Submitted
       | Memory_lane.Coalesced
       | Memory_lane.Dropped
       | Memory_lane.Rejected_draining ->
         fail "stale unexpected cleanup closed the replacement lifecycle")
;;

let crashed_restart_fixture ~base_path name meta =
  let initial = Reg.For_testing.register ~base_path name meta in
  (match
     Reg.dispatch_event_exact
       initial
       (KSM.Fiber_terminated
          { outcome = "fixture crash"; provider_id = None; http_status = None })
   with
   | Ok _ -> ()
   | Error error -> fail (KSM.transition_error_to_string error));
  match Reg.get ~base_path name with
  | Some entry -> entry
  | None -> fail "crashed restart fixture disappeared"
;;

let register_restart ~base_path ~name ~meta token intake_token =
  Reg.register_restarting_for_lifecycle
    ~intake_token
    token
    ~base_path
    name
    meta
;;

let test_launch_callback_failure_rolls_back_restart_transaction () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Memory_lane.For_testing.reset ();
      Masc.Keeper_shutdown_intake_fence.For_testing.reset ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
       Memory_lane.For_testing.reset ();
       let name = "librarian-launch-exception-rollback" in
       let meta = make_meta name in
       let crashed = crashed_restart_fixture ~base_path:config.base_path name meta in
       (match
          Launch_transaction.run
            ~base_path:config.base_path
            ~keeper_name:name
            ~register:(register_restart ~base_path:config.base_path ~name ~meta)
            ~rollback:(Launch_transaction.Restore_previous crashed)
            (fun _intake_token _token _replacement ->
              failwith "injected launch callback failure")
        with
        | Error
            (Launch_transaction.Launch_failed
               { librarian_abort_error = None; rollback_error = None; _ }) -> ()
        | Error _ -> fail "launch exception produced the wrong transaction outcome"
        | Ok _ -> fail "launch exception unexpectedly committed");
       (match Reg.get ~base_path:config.base_path name with
        | Some current ->
          check bool "launch exception restores exact crashed authority" true
            (Lane.Id.equal (Lane.id current.lane) (Lane.id crashed.lane))
        | None -> fail "launch exception removed the durable restart authority");
       (match Memory_lane.submit ~base_path:config.base_path ~keeper_name:name ignore with
        | Memory_lane.Rejected_draining -> ()
        | _ -> fail "failed launch left Librarian admission open");
       match
         Launch_transaction.run
           ~base_path:config.base_path
           ~keeper_name:name
           ~register:(register_restart ~base_path:config.base_path ~name ~meta)
           ~rollback:(Launch_transaction.Restore_previous crashed)
           (fun _intake_token _token replacement -> replacement)
       with
       | Ok replacement ->
         check bool "retry installs a fresh restart lane" false
           (Lane.Id.equal (Lane.id replacement.lane) (Lane.id crashed.lane))
       | Error _ -> fail "retry did not reopen the rolled-back Librarian lifecycle")
;;

let test_launch_callback_cancellation_rolls_back_restart_transaction () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Memory_lane.For_testing.reset ();
      Masc.Keeper_shutdown_intake_fence.For_testing.reset ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
       Memory_lane.For_testing.reset ();
       let name = "librarian-launch-cancellation-rollback" in
       let meta = make_meta name in
       let crashed = crashed_restart_fixture ~base_path:config.base_path name meta in
       let cancel_context, resolve_cancel_context = Eio.Promise.create () in
       let launch_entered, resolve_launch_entered = Eio.Promise.create () in
       let cancelled, resolve_cancelled = Eio.Promise.create () in
       let never, _resolve_never = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         let saw_cancellation =
           try
             Eio.Cancel.sub (fun context ->
               Eio.Promise.resolve resolve_cancel_context context;
               ignore
                 (Launch_transaction.run
                    ~base_path:config.base_path
                    ~keeper_name:name
                    ~register:
                      (register_restart ~base_path:config.base_path ~name ~meta)
                    ~rollback:(Launch_transaction.Restore_previous crashed)
                    (fun _intake_token _token _replacement ->
                       Eio.Promise.resolve resolve_launch_entered ();
                       Eio.Promise.await never)
                   : (_, _) result);
               false)
           with
           | Eio.Cancel.Cancelled _ -> true
         in
         Eio.Promise.resolve resolve_cancelled saw_cancellation);
       let context = Eio.Promise.await cancel_context in
       Eio.Promise.await launch_entered;
       Eio.Cancel.cancel context (Failure "cancel injected launch callback");
       check bool "launch cancellation propagates after rollback" true
         (Eio.Promise.await cancelled);
       (match Reg.get ~base_path:config.base_path name with
        | Some current ->
          check bool "launch cancellation restores exact crashed authority" true
            (Lane.Id.equal (Lane.id current.lane) (Lane.id crashed.lane))
        | None -> fail "launch cancellation removed the durable restart authority");
       (match
          Lifecycle_reservation.current
            ~base_path:config.base_path
            ~keeper_name:name
        with
        | None -> ()
        | Some owner ->
          fail
            ("launch cancellation leaked lifecycle reservation: "
             ^ Lifecycle_reservation.snapshot_to_string owner));
       match Memory_lane.submit ~base_path:config.base_path ~keeper_name:name ignore with
       | Memory_lane.Rejected_draining -> ()
       | _ -> fail "cancelled launch left Librarian admission open")
;;

let test_register_cancellation_rolls_back_restart_transaction () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Memory_lane.For_testing.reset ();
      Masc.Keeper_shutdown_intake_fence.For_testing.reset ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
       Memory_lane.For_testing.reset ();
       let name = "librarian-register-cancellation-rollback" in
       let meta = make_meta name in
       let crashed = crashed_restart_fixture ~base_path:config.base_path name meta in
       let cancel_context, resolve_cancel_context = Eio.Promise.create () in
       let registered, resolve_registered = Eio.Promise.create () in
       let continue_registration, resolve_continue_registration = Eio.Promise.create () in
       let cancelled, resolve_cancelled = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         let saw_cancellation =
           try
             Eio.Cancel.sub (fun context ->
               Eio.Promise.resolve resolve_cancel_context context;
               ignore
                 (Launch_transaction.run
                    ~base_path:config.base_path
                    ~keeper_name:name
                    ~register:(fun token intake_token ->
                      match
                        register_restart
                          ~base_path:config.base_path
                          ~name
                          ~meta
                          token
                          intake_token
                      with
                      | Error _ as error -> error
                      | Ok replacement as ok ->
                        Eio.Promise.resolve resolve_registered replacement;
                        Eio.Promise.await continue_registration;
                        ok)
                    ~rollback:(Launch_transaction.Restore_previous crashed)
                    (fun _intake_token _token _replacement ->
                      Eio.Fiber.yield ();
                      failwith "pending registration cancellation was not delivered")
                  : (_, _) result);
               false)
           with
           | Eio.Cancel.Cancelled _ -> true
         in
         Eio.Promise.resolve resolve_cancelled saw_cancellation);
       let context = Eio.Promise.await cancel_context in
       let replacement = Eio.Promise.await registered in
       Eio.Cancel.cancel context (Failure "cancel injected after registration commit");
       Eio.Promise.resolve resolve_continue_registration ();
       check bool "registration cancellation propagates after rollback" true
         (Eio.Promise.await cancelled);
       (match Reg.get ~base_path:config.base_path name with
        | Some current ->
          check bool "registration cancellation restores exact crashed authority" true
            (Lane.Id.equal (Lane.id current.lane) (Lane.id crashed.lane));
          check bool "registration cancellation removed replacement authority" false
            (Lane.Id.equal (Lane.id current.lane) (Lane.id replacement.lane))
        | None -> fail "registration cancellation removed durable restart authority");
       match Memory_lane.submit ~base_path:config.base_path ~keeper_name:name ignore with
       | Memory_lane.Rejected_draining -> ()
       | _ -> fail "registration cancellation left Librarian admission open")
;;

let test_started_launch_exception_retains_registered_lane () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Memory_lane.For_testing.reset ();
      Masc.Keeper_shutdown_intake_fence.For_testing.reset ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
       let name = "started-launch-exception-retained" in
       let meta = make_meta name in
       let crashed = crashed_restart_fixture ~base_path:config.base_path name meta in
       let started = ref None in
       (match
          Launch_transaction.run
            ~base_path:config.base_path
            ~keeper_name:name
            ~register:(register_restart ~base_path:config.base_path ~name ~meta)
            ~rollback:(Launch_transaction.Restore_previous crashed)
            (fun _intake_token _token replacement ->
               (match
                  Lane.fork
                    ~sw
                    replacement.lane
                    ~run:(fun _ -> ())
                    ~cleanup:(fun _ -> Ok ())
                with
                | Ok () -> started := Some replacement
                | Error error -> fail (Lane.start_error_to_string error));
               failwith "post-fork observation failure")
        with
        | Error (Launch_transaction.Launch_failed { rollback_error = Some _; _ }) -> ()
        | Error _ -> fail "started launch failure lost its retention evidence"
        | Ok _ -> fail "started launch exception unexpectedly committed");
       let expected = Option.get !started in
       match Reg.get ~base_path:config.base_path name with
       | Some current ->
         check bool "started lane remains registry-owned" true
           (Lane.Id.equal (Lane.id current.lane) (Lane.id expected.lane))
       | None -> fail "started launch exception detached the live lane")
;;

let test_offline_launch_exception_retains_retryable_lane () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Memory_lane.For_testing.reset ();
      Masc.Keeper_shutdown_intake_fence.For_testing.reset ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
       let name = "offline-launch-exception-retry" in
       let offline = Reg.register_offline ~base_path:config.base_path name (make_meta name) in
       let run launch =
         Launch_transaction.run
           ~base_path:config.base_path
           ~keeper_name:name
           ~register:(fun _token _intake_token -> Ok offline)
           ~rollback:Launch_transaction.Retain_registered
           launch
       in
       (match
          run (fun _intake_token _token _entry ->
            failwith "injected pre-start callback failure")
        with
        | Error
            (Launch_transaction.Launch_failed
               { librarian_abort_error = None; rollback_error = None; _ }) -> ()
        | Error _ -> fail "offline callback failure produced the wrong transaction outcome"
        | Ok _ -> fail "offline callback failure unexpectedly committed");
       (match Memory_lane.submit ~base_path:config.base_path ~keeper_name:name ignore with
        | Memory_lane.Rejected_draining -> ()
        | _ -> fail "pre-start Offline failure left Librarian admission open");
       let forked = ref false in
       (match
          run (fun _intake_token _token entry ->
            match
              Lane.fork
                ~sw
                entry.lane
                ~run:(fun _ -> forked := true)
                ~cleanup:(fun _ -> Ok ())
            with
            | Ok () -> entry
            | Error error -> fail (Lane.start_error_to_string error))
        with
        | Ok current ->
          check bool "retry preserves exact Offline lane" true
            (Lane.Id.equal (Lane.id current.lane) (Lane.id offline.lane))
        | Error _ -> fail "retained Offline lane was not retryable");
       Eio.Fiber.yield ();
       check bool "retry started the retained Offline lane" true !forked)
;;

let test_restart_intake_epoch_survives_shutdown_overlap () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  ensure_test_runtime ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Reg.For_testing.clear ();
      Memory_lane.For_testing.reset ();
      Masc.Keeper_shutdown_intake_fence.For_testing.reset ();
      Masc.Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       ignore (Masc.Workspace.init config ~agent_name:(Some supervisor_agent_name));
       Memory_lane.For_testing.reset ();
       let name = "restart-intake-shutdown-overlap" in
       let meta = make_meta name in
       let crashed = crashed_restart_fixture ~base_path:config.base_path name meta in
       let registered, resolve_registered = Eio.Promise.create () in
       let continue_launch, resolve_continue_launch = Eio.Promise.create () in
       let finished, resolve_finished = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         let result =
           Launch_transaction.run
             ~base_path:config.base_path
             ~keeper_name:name
             ~register:(fun token intake_token ->
               match
                 register_restart
                   ~base_path:config.base_path
                   ~name
                   ~meta
                   token
                   intake_token
               with
               | Error _ as error -> error
               | Ok replacement as ok ->
                 Eio.Promise.resolve resolve_registered replacement;
                 Eio.Promise.await continue_launch;
                 ok)
             ~rollback:(Launch_transaction.Restore_previous crashed)
             (fun intake_token _token replacement ->
               let bootstrap : Keeper_event_queue.stimulus =
                 { post_id = "restart-intake-token-bootstrap"
                 ; urgency = Keeper_event_queue.Normal
                 ; arrived_at = Unix.gettimeofday ()
                 ; payload = Keeper_event_queue.Bootstrap
                 }
               in
               Masc.Keeper_registry_event_queue.enqueue
                 ~intake_token
                 ~base_path:config.base_path
                 name
                 bootstrap;
               replacement)
         in
         Eio.Promise.resolve resolve_finished result);
       let registered_entry = Eio.Promise.await registered in
       let operation_id = Shutdown_types.Operation_id.generate () in
       (match
          Masc.Keeper_shutdown_intake_fence.begin_shutdown
            ~base_path:config.base_path
            ~keeper_name:name
            ~operation_id
        with
        | Masc.Keeper_shutdown_intake_fence.Reserved _ -> ()
        | Masc.Keeper_shutdown_intake_fence.Already_reserved _ ->
          fail "fresh shutdown operation was already reserved");
       Eio.Promise.resolve resolve_continue_launch ();
       (match Eio.Promise.await finished with
        | Ok launched ->
          check bool "same registered lane crosses Librarian and launch handoff" true
            (Lane.Id.equal (Lane.id launched.lane) (Lane.id registered_entry.lane))
        | Error _ -> fail "create-wins restart epoch was rejected after registration");
       (match
          Masc.Keeper_shutdown_intake_fence.shutdown_operation_id
            ~base_path:config.base_path
            ~keeper_name:name
        with
        | Some actual ->
          check bool "launch does not erase the later shutdown owner" true
            (Shutdown_types.Operation_id.equal operation_id actual)
        | None -> fail "launch erased the later shutdown reservation");
       ignore
         (Masc.Keeper_shutdown_intake_fence.rollback_shutdown
            ~base_path:config.base_path
            ~keeper_name:name
            ~operation_id
          : Masc.Keeper_shutdown_intake_fence.rollback_result))
;;

let () =
  run "keeper_supervisor" [
    "keep_last_n", [
      test_case "under limit" `Quick test_keep_last_n_under_limit;
      test_case "at limit" `Quick test_keep_last_n_at_limit;
      test_case "over limit drops oldest" `Quick test_keep_last_n_over_limit;
    ];
    "boot_meta_materialization", [
      test_case "declarative boot preserves instructions" `Quick
        test_declarative_boot_materializes_instructions;
      test_case "declarative boot allows empty goal links" `Quick
        test_declarative_boot_allows_empty_goal_links;
      test_case "declarative boot re-materializes incompatible persisted meta" `Quick
        test_declarative_boot_rematerializes_incompatible_meta;
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
      test_case "recoverable sweep-owned entries are not relaunched" `Quick
        test_supervise_keepalive_retains_sweep_owned_entries;
      test_case "recoverable launch requires same Offline generation" `Quick
        test_supervise_recovery_requires_same_offline_generation;
      test_case "supervised readiness wakes queued owner operation" `Quick
        test_supervise_keepalive_wakes_ready_operation_drain;
    ];
    "fiber_health", [
      test_case "unknown for unregistered" `Quick test_fiber_health_unknown;
      test_case "registry count zero" `Quick test_registry_count_initially_zero;
      test_case "crash_log empty" `Quick test_crash_log_empty_for_unknown;
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
      test_case "restart reopens crash-aborted Librarian lifecycle" `Quick
        test_restart_reopens_crash_aborted_librarian_lifecycle;
      test_case "restart path emits missing-meta outcome metrics" `Quick
        test_restart_path_emits_meta_unavailable_outcome_metric;
      test_case "active Librarian abort defers then retries restart" `Quick
        test_active_librarian_abort_defers_then_retries_restart;
      test_case "unexpected cleanup preserves reopened Librarian lifecycle" `Quick
        test_unexpected_cleanup_cannot_close_reopened_librarian_lifecycle;
      test_case "launch callback failure rolls back restart transaction" `Quick
        test_launch_callback_failure_rolls_back_restart_transaction;
      test_case "launch callback cancellation rolls back restart transaction" `Quick
        test_launch_callback_cancellation_rolls_back_restart_transaction;
      test_case "register cancellation rolls back restart transaction" `Quick
        test_register_cancellation_rolls_back_restart_transaction;
      test_case "started launch exception retains registered lane" `Quick
        test_started_launch_exception_retains_registered_lane;
      test_case "offline launch exception retains retryable lane" `Quick
        test_offline_launch_exception_retains_retryable_lane;
      test_case "restart intake epoch survives shutdown overlap" `Quick
        test_restart_intake_epoch_survives_shutdown_overlap;
    ];
    "stale_storm_phase2", [
      test_case "supervisor cleanup suppresses cancellation and classifies failures" `Quick
        test_supervisor_cleanup_suppresses_cancellation_and_classifies_failures;
      test_case "supervised stop joins Board worker" `Quick
        test_supervised_stop_joins_board_attention_worker;
      test_case "supervised stop drains Librarian before terminal" `Quick
        test_supervised_stop_drains_librarian_before_terminal;
      test_case "lane fork reject does not announce Running" `Quick
        test_launch_fork_rejection_does_not_announce_running;
      test_case "fork reject preserves newer same-name lane" `Quick
        test_fork_rejection_preserves_replacement_lane;
      test_case "sweep joins lane before unregister" `Quick
        test_sweep_waits_for_lane_join_before_unregister;
      test_case "idle duration never stops keeper" `Quick
        test_idle_duration_never_stops_keeper;
      test_case "non-storm Crashed still routes to restart (regression guard)" `Quick
        test_non_storm_crashed_restarts_normally;
    ];
  ]
