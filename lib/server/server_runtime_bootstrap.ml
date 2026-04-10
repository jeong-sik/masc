
open Server_auth
open Server_routes_http

module Mcp_server = Mcp_server
module Mcp_eio = Mcp_server_eio

let pg_env_var_names =
  [| "MASC_POSTGRES_URL" |]

let force_jsonl_fallback_env () =
  Unix.putenv "MASC_STORAGE_TYPE" "filesystem";
  Array.iter (fun name -> Unix.putenv name "") pg_env_var_names

let requested_backend_mode () =
  Env_config_core.storage_type ()

let ensure_default_oas_cascade_timeout_env () =
  match Sys.getenv_opt "OAS_CASCADE_MODEL_TIMEOUT_SEC" |> Env_config_core.trim_opt with
  | Some _ -> ()
  | None ->
      let keeper_oas_timeout_s = Env_config_keeper.KeeperKeepalive.oas_timeout_sec in
      let derived_timeout_s =
        Float.max 30.0 (Float.min 120.0 (keeper_oas_timeout_s /. 5.0))
      in
      Unix.putenv "OAS_CASCADE_MODEL_TIMEOUT_SEC"
        (Printf.sprintf "%.0f" derived_timeout_s)

let project_root_from_executable () =
  let raw_exe =
    try Sys.executable_name with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ""
  in
  let exe =
    if String.equal raw_exe "" then ""
    else
      try Unix.realpath raw_exe
      with Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> raw_exe
  in
  if String.equal exe "" then None
  else
    let rec walk_up dir =
      let parent = Filename.dirname dir in
      if String.equal parent dir then None
      else if String.equal (Filename.basename dir) "_build" then Some parent
      else walk_up parent
    in
    walk_up (Filename.dirname exe)

let dedupe_keep_order items =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
      if Hashtbl.mem seen item then
        false
      else (
        Hashtbl.add seen item ();
        true))
    items

let versioned_config_root_candidates () =
  let cwd_candidate = Filename.concat (Sys.getcwd ()) "config" in
  let exe_candidate =
    match project_root_from_executable () with
    | Some root -> Some (Filename.concat root "config")
    | None -> None
  in
  [ Some cwd_candidate; exe_candidate ]
  |> List.filter_map (fun x -> x)
  |> dedupe_keep_order
  |> List.filter (fun path -> Sys.file_exists path && Sys.is_directory path)

let copy_file_if_missing ~src ~dst =
  if Sys.file_exists dst then
    ()
  else begin
    Fs_compat.mkdir_p (Filename.dirname dst);
    Fs_compat.save_file dst (Fs_compat.load_file src)
  end

let rec copy_missing_tree ~src ~dst =
  if Sys.is_directory src then begin
    if Sys.file_exists dst && not (Sys.is_directory dst) then
      Log.Server.warn
        "config bootstrap: refusing to replace file with directory (%s -> %s)"
        src dst
    else begin
      Fs_compat.mkdir_p dst;
      Sys.readdir src
      |> Array.iter (fun name ->
             copy_missing_tree
               ~src:(Filename.concat src name)
               ~dst:(Filename.concat dst name))
    end
  end else if Sys.file_exists dst then
    ()
  else
    copy_file_if_missing ~src ~dst

let bootstrap_base_path_config_root ~base_path =
  let base_path = Env_config_core.normalize_masc_base_path_input base_path in
  if Option.is_some (Env_config_core.config_dir_opt ()) then
    ()
  else
    let config_root =
      Filename.concat (Filename.concat base_path ".masc") "config"
    in
    let source_root =
      versioned_config_root_candidates () |> List.find_opt Sys.file_exists
    in
    (match source_root with
     | Some source ->
         copy_missing_tree ~src:source ~dst:config_root;
         Log.Server.info
           "bootstrapped base-path config root: %s <- %s"
           config_root source
     | None ->
         Fs_compat.mkdir_p (Filename.concat config_root "prompts");
         Fs_compat.mkdir_p (Filename.concat config_root "keepers");
         Fs_compat.mkdir_p (Filename.concat config_root "personas");
         if not (Sys.file_exists (Filename.concat config_root "cascade.json")) then
           Fs_compat.save_file (Filename.concat config_root "cascade.json") "{}";
         Log.Server.warn
           "bootstrapped minimal base-path config root without versioned source: %s"
           config_root);
    Config_dir_resolver.reset ()

let startup_config_resolution ~base_path =
  Config_dir_resolver.resolve_with
    Config_dir_resolver.
      {
        cwd = Sys.getcwd ();
        executable_name = Sys.executable_name;
        env_base_path = Some base_path;
        env_config_dir = Env_config_core.config_dir_opt ();
        env_personas_dir = Env_config_core.personas_dir_opt ();
        env_home = Sys.getenv_opt "HOME";
      }

(* GC tuning for long-running server with bursty allocation.

   Dashboard refresh loops create 2GB+ transient allocations per cycle.
   With aggressive GC (space_overhead=40), major GC slices walk
   MADV_FREE'd pages on macOS, triggering page faults that freeze the
   Eio event loop — blocking /health and all HTTP endpoints.

   Only apply defaults when OCAMLRUNPARAM is not set, so operators
   can override at launch without code changes. *)
let () =
  if Option.is_none (Sys.getenv_opt "OCAMLRUNPARAM") then begin
    let open Gc in
    let ctrl = get () in
    set { ctrl with
      minor_heap_size = 2 * 1024 * 1024;  (* 2M words = 16MB on 64-bit; reduces minor->major promotion rate *)
      space_overhead = 200;               (* default 120; less frequent major GC slices *)
      max_overhead = 500;                 (* compaction triggers when free memory exceeds 500% of live data *)
    }
  end

let init_runtime_context env =
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let net = Eio.Stdenv.net env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let fs = Eio.Stdenv.fs env in
  (clock, mono_clock, net, domain_mgr, proc_mgr, fs)

let create_server_state ~sw ~base_path ~clock ~mono_clock ~net ~proc_mgr ~fs
    : Mcp_server.server_state =
  let input_base_path =
    match String.trim base_path with
    | "" -> None
    | raw -> Some raw
  in
  let base_path = Env_config_core.normalize_masc_base_path_input base_path in
  Fs_compat.set_fs fs;
  Mcp_eio.set_net net;
  Mcp_eio.set_clock clock;
  Eio_context.set_switch sw;
  Eio_context.set_net net;
  Eio_context.set_clock clock;
  Eio_context.set_mono_clock mono_clock;
  ensure_default_oas_cascade_timeout_env ();
  Process_eio.init ~cwd_default:Eio.Path.(fs / base_path) ~proc_mgr ~clock;
  let caqti_env : Caqti_eio.stdenv =
    object
      method net = (net :> [`Generic] Eio.Net.ty Eio.Resource.t)
      method clock = clock
      method mono_clock = mono_clock
    end
  in
  Unix.putenv "MASC_BASE_PATH_INPUT" (Option.value ~default:"" input_base_path);
  Unix.putenv "MASC_BASE_PATH" base_path;
  bootstrap_base_path_config_root ~base_path;
  (* RFC-0001 Gate A: initialize instrumentation stores *)
  Heuristic_metrics.init ~base_path;
  Agent_stress.init ~base_path;
  (* Load tool policy presets from config/tool_policy.toml *)
  (match Keeper_exec_tools.init_policy_config ~base_path with
   | Ok () -> ()
   | Error msg ->
       Log.Server.error "Fatal tool policy config load failure: %s" msg;
       exit 1);
  (* Validate Tool_spec <-> TOML coverage *)
  let validation = Tool_registration_check.validate () in
  Tool_registration_check.log_validation_result validation;
  let state =
    Mcp_eio.create_state_eio ~sw ~env:caqti_env ~proc_mgr ~fs ~clock
      ~mono_clock ~net
      ~base_path
  in
  let config_resolution =
    startup_config_resolution ~base_path |> Config_dir_resolver.to_json
  in
  let path_diagnostics =
    Server_base_path_diagnostics.detect
      ?input_base_path
      ?env_masc_base_path:(Env_config_core.base_path_raw_opt ())
      ~effective_base_path:state.room_config.base_path
      ~effective_masc_root:(Room.masc_root_dir state.room_config)
      ()
    |> Server_base_path_diagnostics.to_yojson
  in
  Server_startup_state.note_runtime_resolution ~path_diagnostics
    ~config_resolution;
  state

let runtime_path_diagnostics ?input_base_path (state : Mcp_server.server_state) =
  Server_base_path_diagnostics.detect
    ?input_base_path
    ?env_masc_base_path:(Env_config_core.base_path_raw_opt ())
    ~effective_base_path:state.room_config.base_path
    ~effective_masc_root:(Room.masc_root_dir state.room_config)
    ()

let restore_persisted_sessions (state : Mcp_server.server_state) =
  Session.restore_from_disk state.session_registry
    ~agents_path:(Room.agents_dir state.room_config)

let reconcile_active_agents_gauge (state : Mcp_server.server_state) =
  Prometheus.reconcile_active_agents_gauge (Room.masc_dir state.room_config)

(** Migrate legacy directory names: perpetual->traces, resident-keepers->keepers.
    Moves contents via recursive merge. Conflicting files go to _quarantine/,
    except keeper meta files where a fresher valid legacy record may replace a
    stale or invalid current record. *)
let keeper_meta_updated_ts (meta : Keeper_types.keeper_meta) =
  Resilience.Time.parse_iso8601_opt meta.updated_at
  |> Option.value ~default:0.0

let should_promote_legacy_keeper_meta ~legacy_path ~current_path =
  match
    Keeper_types.read_meta_file_path legacy_path,
    Keeper_types.read_meta_file_path current_path
  with
  | Ok (Some _legacy), Ok (Some _current) -> (
      keeper_meta_updated_ts _legacy > keeper_meta_updated_ts _current)
  | Ok (Some _), Ok None | Ok (Some _), Error _ -> true
  | _ -> false

let migrate_legacy_dirs_with_renames (state : Mcp_server.server_state) renames =
  let masc_root = Room.masc_root_dir state.room_config in
  let quarantine_rel_path ~source_name ~rel_path =
    if rel_path = "" then source_name else Filename.concat source_name rel_path
  in
  let quarantine = Filename.concat masc_root "_quarantine" in
  let quarantine_replaced_path ~source_name ~rel_path =
    Filename.concat quarantine
      (Filename.concat "_replaced"
         (quarantine_rel_path ~source_name ~rel_path))
  in
  let rec migrate_recursive ~source_name ~old_dir ~new_dir ~rel_path
      ~prefer_root_keeper_meta_conflicts
      ~prefer_room_flatten_conflicts =
    if not (Sys.file_exists old_dir) then ()
    else begin
      Keeper_types.mkdir_p new_dir;
      Array.iter (fun name ->
        let old_path = Filename.concat old_dir name in
        let new_path = Filename.concat new_dir name in
        let rel = if rel_path = "" then name else Filename.concat rel_path name in
        if Sys.is_directory old_path then begin
          if Sys.file_exists new_path then
            migrate_recursive ~source_name ~old_dir:old_path ~new_dir:new_path ~rel_path:rel
              ~prefer_root_keeper_meta_conflicts
              ~prefer_room_flatten_conflicts
          else
            Sys.rename old_path new_path
        end else begin
          if Sys.file_exists new_path then begin
            if prefer_root_keeper_meta_conflicts && rel_path = ""
               && Filename.check_suffix name ".json"
               && should_promote_legacy_keeper_meta
                    ~legacy_path:old_path ~current_path:new_path
            then begin
              let replaced_q_path = quarantine_replaced_path ~source_name ~rel_path:rel in
              Keeper_types.mkdir_p (Filename.dirname replaced_q_path);
              Sys.rename new_path replaced_q_path;
              Sys.rename old_path new_path
            end else if prefer_room_flatten_conflicts then begin
              let replaced_q_path = quarantine_replaced_path ~source_name ~rel_path:rel in
              Keeper_types.mkdir_p (Filename.dirname replaced_q_path);
              Sys.rename new_path replaced_q_path;
              Sys.rename old_path new_path
            end else begin
              let q_path =
                Filename.concat quarantine
                  (quarantine_rel_path ~source_name ~rel_path:rel)
              in
              Keeper_types.mkdir_p (Filename.dirname q_path);
              Sys.rename old_path q_path
            end
          end else
            Sys.rename old_path new_path
        end
      ) (Sys.readdir old_dir);
      (try
        if Array.length (Sys.readdir old_dir) = 0 then
          Sys.rmdir old_dir
        else
          Log.Misc.warn "migrate: old dir not empty after migration: %s" old_dir
      with Sys_error _ -> ())
    end
  in
  (try
    List.iter (fun (old_name, new_name) ->
      let old_dir = Filename.concat masc_root old_name in
      let new_dir = Filename.concat masc_root new_name in
      if Sys.file_exists old_dir then begin
        Log.Misc.info "migrate: %s -> %s" old_name new_name;
        migrate_recursive ~source_name:old_name ~old_dir ~new_dir ~rel_path:""
          ~prefer_root_keeper_meta_conflicts:(String.equal new_name "keepers")
          ~prefer_room_flatten_conflicts:(String.starts_with ~prefix:"rooms/" old_name)
      end
    ) renames
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.error "legacy dir migration failed: %s" (Printexc.to_string exn))

let migrate_legacy_dirs (state : Mcp_server.server_state) =
  migrate_legacy_dirs_with_renames state
    [ ("perpetual", "traces"); ("resident-keepers", "keepers") ]

let migrate_legacy_keeper_dirs_blocking (state : Mcp_server.server_state) =
  migrate_legacy_dirs_with_renames state [ ("resident-keepers", "keepers") ]

let default_room_for_flat_migration = "focus-room"

let legacy_room_candidates rooms_dir =
  if not (Sys.file_exists rooms_dir) then
    []
  else
    try
      Sys.readdir rooms_dir
      |> Array.to_list
      |> List.filter_map (fun room_id ->
           let room_path = Filename.concat rooms_dir room_id in
           if Sys.is_directory room_path then
             let trimmed_room_id = String.trim room_id in
             if not (String.equal room_id trimmed_room_id) then begin
               Log.Misc.warn
                 "migrate: ignoring invalid legacy room dir %S (must not have leading/trailing whitespace)"
                 room_id;
               None
             end else
               match Room.validate_room_id room_id with
               | Ok valid_room_id -> Some valid_room_id
               | Error msg ->
                 Log.Misc.warn
                   "migrate: ignoring invalid legacy room dir %s (%s)" room_id
                   msg;
                   None
           else
             None)
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> []

let infer_current_room_from_legacy_dirs rooms_dir =
  match legacy_room_candidates rooms_dir with
  | [ room_id ] ->
      Log.Misc.info
        "migrate: current_room unavailable; using only legacy room %s" room_id;
      Some room_id
  | room_ids when List.mem default_room_for_flat_migration room_ids ->
      Log.Misc.info
        "migrate: current_room unavailable; using legacy room %s"
        default_room_for_flat_migration;
      Some default_room_for_flat_migration
  | [] -> None
  | room_ids ->
      Log.Misc.warn
        "migrate: current_room unavailable and multiple legacy rooms exist (%s); skipping room flatten"
        (String.concat ", " room_ids);
      None

let load_current_room_or_default masc_root rooms_dir =
  let path = Filename.concat masc_root "current_room" in
  if not (Sys.file_exists path) then
    infer_current_room_from_legacy_dirs rooms_dir
  else
    match Safe_ops.read_file_safe path with
    | Error msg ->
        Log.Misc.warn
          "migrate: failed to read %s (%s); probing legacy room dirs instead"
          path msg;
        infer_current_room_from_legacy_dirs rooms_dir
    | Ok raw -> (
        match Room.validate_room_id (String.trim raw) with
        | Ok room_id -> Some room_id
        | Error msg ->
            Log.Misc.warn
              "migrate: ignoring invalid current_room in %s (%s); probing legacy room dirs instead"
              path msg;
            infer_current_room_from_legacy_dirs rooms_dir)

let migrate_room_to_flat (state : Mcp_server.server_state) =
  let masc_root = Room.masc_root_dir state.room_config in
  let rooms_dir = Filename.concat masc_root "rooms" in
  if not (Sys.file_exists rooms_dir) then ()
  else begin
    match load_current_room_or_default masc_root rooms_dir with
    | Some current_room ->
        let room_dir = Filename.concat rooms_dir current_room in
        if Sys.file_exists room_dir && Sys.is_directory room_dir then begin
          Log.Misc.info "migrate: flattening room %s to .masc/ root" current_room;
          migrate_legacy_dirs_with_renames state
            [ (Filename.concat "rooms" current_room, ".") ]
        end else if current_room = "default" then
          Log.Misc.info "migrate: legacy rooms/ exists but default room not found (likely already flattened)"
        else
          Log.Misc.warn "migrate: rooms/ exists but active room %s not found" current_room
    | None ->
        Log.Misc.warn
          "migrate: rooms/ exists but no safe current room could be inferred; leaving legacy room dirs untouched"
  end

let migrate_legacy_trace_dirs (state : Mcp_server.server_state) =
  migrate_legacy_dirs_with_renames state [ ("perpetual", "traces") ]

let bootstrap_server_state_blocking (state : Mcp_server.server_state) =
  (* Promote legacy room/keeper state before Room.init seeds fresh root files.
     Otherwise state.json/backlog.json can be created in the destination first
     and valid legacy data gets quarantined as a conflict on upgrade. *)
  migrate_room_to_flat state;
  (* Promote legacy keeper metadata before any startup readers scan .masc/keepers.
     Keeper autoboot and other bootstrap readers should see the canonical paths
     on their first pass, not rely on a later lazy migration task. *)
  migrate_legacy_keeper_dirs_blocking state;
  let (_init_msg : string) = Room.init state.room_config ~agent_name:None in
  Mcp_server.set_sse_callback state Sse.broadcast

let bootstrap_prompt_state (state : Mcp_server.server_state) =
  Config_dir_resolver.log_warnings ~context:"ServerBootstrap" ();
  (* Initialize prompt registry with defaults and restore saved overrides *)
  let prompt_markdown_dir =
    Prompt_defaults.bootstrap_runtime
      ~workspace_path:state.room_config.workspace_path
      ~base_path:state.room_config.base_path
  in
  let expected_prompt_dir = Config_dir_resolver.prompts_dir () in
  if prompt_markdown_dir <> expected_prompt_dir then
    Log.Misc.warn
      "prompt markdown dir diverges from resolved config root: %s (expected %s)"
      prompt_markdown_dir expected_prompt_dir;
  let missing_prompt_files = Prompt_registry.validate_required_prompt_files () in
  if missing_prompt_files <> [] then
    Log.Misc.error "required prompt files missing: %s"
      (missing_prompt_files
      |> List.map (fun (key, path) -> Printf.sprintf "%s -> %s" key path)
      |> String.concat ", ");
  let invalid_prompt_templates = Prompt_registry.validate_prompt_templates () in
  if invalid_prompt_templates <> [] then
    Log.Misc.error "prompt templates use unknown variables: %s"
      (invalid_prompt_templates
      |> List.map (fun (key, variable) -> Printf.sprintf "%s -> %s" key variable)
      |> String.concat ", ")

let warm_tool_registry_from_telemetry (state : Mcp_server.server_state) =
  (try
     let summary =
       Telemetry_eio.summarize_tool_usage state.room_config
     in
     if summary.telemetry_available then
       let n = Tool_registry.warm_up summary in
       Log.Misc.info "tool registry: warmed up %d tools (%d calls) from telemetry"
         n summary.total_calls
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.error "tool registry warm-up failed: %s"
       (Printexc.to_string exn))

let restore_tool_metrics_from_disk (state : Mcp_server.server_state) =
  (try
     let n = Tool_metrics_persist.restore
       ~base_path:state.room_config.base_path in
     if n > 0 then
       Log.Misc.info "tool metrics: restored %d records from disk" n
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.error "tool metrics restore failed: %s"
       (Printexc.to_string exn))

let startup_prune_jsonl (state : Mcp_server.server_state) =
  (try
     let days =
       Safe_ops.get_env_int_logged "MASC_JSONL_RETENTION_DAYS" ~default:30
     in
     let masc = Room.masc_dir state.room_config in
     let prune_dir dir =
       if Sys.file_exists dir then
         Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days
       else 0
     in
     let tool_metrics_dir =
       Filename.concat state.room_config.base_path "data/tool-metrics"
     in
     let total =
       prune_dir (Filename.concat masc "audit")
       + prune_dir (Filename.concat masc "telemetry")
       + prune_dir (Filename.concat (Filename.concat masc "governance") "judgments")
       + prune_dir tool_metrics_dir
       + prune_dir (Filename.concat masc "messages")
       + prune_dir (Filename.concat masc "events")
       + prune_dir (Filename.concat masc "activity-events")
       + prune_dir (Filename.concat masc "voice_sessions")
       + (let keepers = Filename.concat masc "keepers" in
          if not (Sys.file_exists keepers) then 0
          else
            Array.fold_left (fun acc name ->
              acc
              + prune_dir (Filename.concat (Filename.concat keepers name) "metrics")
              + prune_dir (Filename.concat (Filename.concat keepers name) "crash-events")
            ) 0 (Sys.readdir keepers))
     in
     if total > 0 then
         Log.Misc.info "startup prune: deleted %d old JSONL day-files (retention=%dd)"
         total days
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn -> Log.Misc.error "startup prune failed: %s" (Printexc.to_string exn))

let startup_prune_keeper_checkpoints (state : Mcp_server.server_state) =
  (try
     let traces_dir =
       Filename.concat (Room.masc_root_dir state.room_config) "traces"
     in
     if Sys.file_exists traces_dir then begin
       let total = ref 0 in
       Array.iter (fun trace_name ->
         let trace_dir = Filename.concat traces_dir trace_name in
         if Sys.is_directory trace_dir then begin
           let files = Sys.readdir trace_dir |> Array.to_list in
           let ckpt_files =
             files
             |> List.filter (fun f ->
               let len = String.length f in
               len > 5 && String.sub f 0 5 = "ckpt-"
               && String.sub f (len - 5) 5 = ".json")
             |> List.sort (fun a b -> compare b a)
           in
           if List.length ckpt_files > 3 then
             List.iteri (fun i f ->
               if i >= 3 then begin
                 (try Sys.remove (Filename.concat trace_dir f)
                  with Sys_error _ -> ());
                 incr total
               end
             ) ckpt_files
         end
       ) (Sys.readdir traces_dir);
       if !total > 0 then
         Log.Misc.info "startup prune: deleted %d old keeper checkpoint files" !total
     end
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.error "startup checkpoint prune failed: %s"
       (Printexc.to_string exn))

(* bootstrap_keepers removed: the keeper_autoboot subsystem in
   start_keeper_loops now handles keeper startup in a dedicated
   fiber with a 5-second delay, avoiding PG pool contention with
   the 7+ dashboard refresh loops that share the same pool. *)

let run ~sw ~env ~host ~port ~base_path ~make_routes ~make_request_handler
    ~make_h2_request_handler ~make_h2_error_handler =
  let clock, mono_clock, net, domain_mgr, proc_mgr, fs =
    init_runtime_context env
  in

  (* Initialize Eio environment for MODEL HTTP calls (cohttp-eio via OAS Provider) *)
  Masc_eio_env.init ~sw ~net ~clock ();
  Discovery_cache.set_env ~sw ~net;
  Discovery_cache.set_base_path base_path;
  (* Start global rate-limit bucket cleanup loop to prevent unbounded growth of
     per-client buckets.  The loop is a background fiber that wakes periodically
     and removes stale entries according to MASC_RATE_LIMIT_ENTRY_MAX_AGE_SEC. *)
  Rate_limit.start_global_cleanup_loop ~sw ~clock;
  let refresh_llama_endpoints () =
    try
      let llama_endpoints =
        Llm_provider.Provider_registry.refresh_llama_endpoints ~sw ~net ()
      in
      Log.Server.info "[MASC] Llama endpoints: %s"
        (String.concat ", " llama_endpoints)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.warn "llama endpoint refresh skipped during startup: %s"
        (Printexc.to_string exn)
  in

  (* 1. HTTP socket first — Railway healthcheck can reach /health immediately *)
  let config = Server_bootstrap_http.make_http_config ~host ~port in
  let routes = make_routes ~port:config.port ~host:config.host ~sw ~clock in
  let request_handler = make_request_handler routes in
  let h2_request_handler =
    make_h2_request_handler ~sw ~clock ~server_start_time
  in
  let h2_error_handler = make_h2_error_handler () in
  let http_mode =
    match Env_config.Transport.use_h2 () with
    | "h2_only" -> `H2_only
    | "h1_only" -> `H1_only
    | _ -> `Auto
  in
  let socket = Server_bootstrap_http.listen_socket ~sw ~net config in
  let initial_backend_mode = requested_backend_mode () in
  server_state := None;
  Server_startup_state.reset ~backend_mode:initial_backend_mode ();

  (* 2. All init in background fiber — protected so failures don't kill HTTP *)
  Eio.Fiber.fork ~sw (fun () ->
    refresh_llama_endpoints ();
    let governance_level = Env_config_core.governance_level () in
    let init_state_blocking () =
      let t0 = Eio.Time.now clock in
      let state =
        create_server_state ~sw ~base_path ~clock ~mono_clock ~net ~proc_mgr ~fs
      in
      let t1 = Eio.Time.now clock in
      Log.Server.info "State created (PG pool) in %.1fs" (t1 -. t0);
      bootstrap_server_state_blocking state;
      let path_diagnostics =
        runtime_path_diagnostics ~input_base_path:base_path state
      in
      Server_base_path_diagnostics.log_startup_warning path_diagnostics;
      if Server_base_path_diagnostics.strict_violation path_diagnostics then begin
        Log.Server.error "%s\nSet MASC_BASE_PATH explicitly or unset MASC_BASE_PATH_STRICT to recover."
          (Option.value path_diagnostics.warning
             ~default:
               "strict base-path guard triggered without a diagnostic warning");
        exit 1
      end;
      Governance_registry.ensure_init ();
      Runtime_params.restore ~base_path;
      Log.Server.info "Runtime_params restored from %s" base_path;
      Keeper_crash_persistence.start_drain_fiber ~sw ~clock;
      let t2 = Eio.Time.now clock in
      Log.Server.info "Bootstrap completed in %.1fs" (t2 -. t1);
      Server_bootstrap_loops.install_tooling ~governance_level state;
      Server_bootstrap_pg.init_pg_schemas_sequential ();
      Log.Server.info "Tooling + schemas in %.1fs" (Eio.Time.now clock -. t2);
      (state, path_diagnostics)
    in
    let run_lazy_task (task_name, task_fn) =
      Log.Server.info "lazy_task: starting %s" task_name;
      try
        task_fn ();
        Log.Server.info "lazy_task: finished %s" task_name;
        Server_startup_state.finish_lazy_task ~task:task_name
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          let error = Printexc.to_string exn in
          Log.Server.error "lazy startup task %s failed: %s" task_name error;
          Server_startup_state.fail_lazy_task ~task:task_name ~error
    in
    let start_lazy_startup state =
      let masc_root = Room.masc_root_dir state.Mcp_server.room_config in
      let has_legacy_traces =
        Sys.file_exists (Filename.concat masc_root "perpetual")
      in
      let tasks =
        [
          ("restore_sessions", fun () -> restore_persisted_sessions state);
          ("reconcile_active_agents", fun () -> reconcile_active_agents_gauge state);
          ( "recover_running_sessions",
            fun () ->
              match state.Mcp_server.proc_mgr, state.Mcp_server.net with
              | None, _ ->
                  Log.Server.warn
                    "skipping session recovery: process_mgr not available"
              | Some _process_mgr, None ->
                  Log.Server.warn
                    "skipping session recovery: net not available"
              | Some _process_mgr, Some _net ->
                  (* Team_session_engine_eio removed — skip recovery *)
                  ignore (sw, clock, state.Mcp_server.room_config) );
          ("prompt_bootstrap", fun () -> bootstrap_prompt_state state);
          ("telemetry_warmup", fun () -> warm_tool_registry_from_telemetry state);
          ("tool_metrics_restore", fun () -> restore_tool_metrics_from_disk state);
        ]
        @ (if has_legacy_traces then
             [("legacy_trace_dir_migration", fun () ->
                 migrate_legacy_trace_dirs state)]
           else [])
        @ [
          ("jsonl_prune", fun () -> startup_prune_jsonl state);
          ( "keeper_checkpoint_prune",
            fun () -> startup_prune_keeper_checkpoints state );
          (* keeper_bootstrap removed: keeper_autoboot subsystem in
             start_keeper_loops handles this in a dedicated fiber,
             avoiding PG pool contention with dashboard refresh loops. *)
        ]
      in
      let task_names = List.map fst tasks in
      Server_startup_state.activate_lazy
        ~backend_mode:(Room.backend_name state.room_config)
        ~tasks:task_names;
      Eio.Fiber.fork ~sw (fun () -> List.iter run_lazy_task tasks)
    in
    try
      let pg_init_timeout =
        Safe_ops.get_env_float_logged "MASC_PG_INIT_TIMEOUT_SEC" ~default:30.0
      in
      Server_startup_state.mark_blocking ~backend_mode:initial_backend_mode;
      let state, path_diagnostics =
        if String.equal initial_backend_mode "postgres-native" then
          (try
             Eio.Time.with_timeout_exn clock pg_init_timeout init_state_blocking
           with Eio.Time.Timeout ->
             let reason =
               Printf.sprintf
                 "PG init timed out after %.0fs with MASC_STORAGE_TYPE=postgres"
                 pg_init_timeout
             in
             Log.Server.error "%s" reason;
             raise (Invalid_argument reason))
        else
          init_state_blocking ()
      in
      server_state := Some state;
      Server_startup_state.mark_state_ready
        ~backend_mode:(Room.backend_name state.room_config);
      let resolved_base, masc_dir =
        Server_bootstrap_loops.start_background_maintenance ~sw ~clock ~env state
      in
      Server_bootstrap_http.print_startup_banner ~config ~resolved_base ~base_path
        ~masc_dir ~path_diagnostics;
      (* Create Executor_pool for CPU-heavy dashboard compute.
         Runs in separate OS domains, bypassing fiber contention. *)
      let exec_pool = Eio.Executor_pool.create ~sw ~domain_count:2 domain_mgr in
      Server_dashboard_http.set_executor_pool exec_pool;
      Log.Server.info "Executor_pool created (2 domains) for dashboard";
      (* Start auxiliary transports before optional warmups and keeper loops.
         Otherwise HTTP can report ready while gRPC/WS startup is still stuck
         behind heavier startup work. *)
      (* gRPC coordination transport (default-on, opt-out via MASC_GRPC_ENABLED=0) *)
      let tool_dispatcher tool_name args_json =
        let arguments =
          try Yojson.Safe.from_string args_json
          with Yojson.Json_error _ -> `Assoc []
        in
        let (success, result_str) =
          Mcp_server_eio_execute.execute_tool_eio ~sw ~clock state
            ~name:tool_name ~arguments
        in
        if not success then
          Log.Server.error "gRPC tool call failed: tool=%s error_bytes=%d"
            tool_name (String.length result_str);
        if success then Ok result_str else Error result_str
      in
      Masc_grpc_server.start ~sw ~env ~room_config:state.room_config
        ~tool_dispatcher;
      (* Initialize gRPC client for keeper heartbeat when transport is gRPC *)
      (match Masc_grpc_transport.from_env () with
       | Masc_grpc_transport.Grpc ->
           (try
              let client = Masc_grpc_client.create_from_env ~sw ~env in
              Keeper_keepalive.set_grpc_client ~env client;
              Log.Server.info "gRPC keeper client initialized"
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              Log.Server.warn "gRPC keeper client init failed: %s"
                (Printexc.to_string exn))
       | _ -> ());
      (* Standalone WebSocket transport (enabled by default, opt-out via MASC_WS_ENABLED=0) *)
      Server_ws_standalone.start ~sw ~env
        ~on_message:(fun ws_session_id body_str ->
          Eio.Fiber.fork ~sw (fun () ->
            try
              let response_json =
                Mcp_eio.handle_request ~clock ~sw
                  ~mcp_session_id:ws_session_id state body_str
              in
              let response_str = Yojson.Safe.to_string response_json in
              if response_str <> "null" then
                ignore (Server_mcp_transport_ws.send_to_session ws_session_id response_str)
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Server.warn "WS dispatch error %s: %s" ws_session_id (Printexc.to_string exn)));
      (* WebRTC DataChannel transport (enabled by default, opt-out via MASC_WEBRTC_ENABLED=0) *)
      if Server_webrtc_transport.is_enabled () then (
        Log.Server.info "WebRTC DataChannel transport enabled";
        Server_webrtc_transport.set_message_handler
          (fun peer_id body_str ->
            Eio.Fiber.fork ~sw (fun () ->
              try
                let response_json =
                  Mcp_eio.handle_request ~clock ~sw
                    ~mcp_session_id:peer_id state body_str
                in
                let response_str = Yojson.Safe.to_string response_json in
                if response_str <> "null" then
                  ignore (Server_webrtc_transport.send_to_peer peer_id response_str)
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Server.warn "WebRTC dispatch error %s: %s"
                  peer_id (Printexc.to_string exn)));
        Server_webrtc_transport.set_connection_starter
          (fun peer_id ->
            Server_webrtc_transport.start_webrtc_connection ~sw ~env peer_id));
      (* Register transport providers for unified bridge *)
      Transport_bridge.register_provider (module struct
        let name = "sse"
        let protocol = Transport.Sse
        let is_enabled () = true  (* SSE is always enabled *)
        let session_count () = Sse.client_count ()
        let status_json () = `Assoc [
          "clients", `Int (Sse.client_count ());
          "external_subscribers", `Int (Sse.external_subscriber_count ());
        ]
        let reap_stale () = List.length (Sse.cleanup_stale ())
      end);
      Transport_bridge.register_provider (module struct
        let name = "ws"
        let protocol = Transport.Ws
        let is_enabled () = Server_ws_standalone.is_enabled ()
        let session_count () = Server_mcp_transport_ws.session_count ()
        let status_json () = `Assoc [
          "port", `Int (Server_ws_standalone.configured_port ());
          "sessions", `Int (Server_mcp_transport_ws.session_count ());
        ]
        let reap_stale () = 0  (* WS sessions self-clean on disconnect *)
      end);
      Transport_bridge.register_provider (module struct
        let name = "grpc"
        let protocol = Transport.Grpc
        let is_enabled () = Masc_grpc_server.is_enabled ()
        let session_count () = 0  (* gRPC uses per-call, no persistent sessions *)
        let status_json () = `Assoc [
          "port", `Int (Masc_grpc_server.configured_port ());
          "service", `String Masc_grpc_service.service_name;
        ]
        let reap_stale () = 0
      end);
      Transport_bridge.register_provider (module struct
        let name = "webrtc"
        let protocol = Transport.Webrtc
        let is_enabled () = Server_webrtc_transport.is_enabled ()
        let session_count () = Server_webrtc_transport.live_webrtc_count ()
        let status_json () = `Assoc [
          "active_peers", `Int (Server_webrtc_transport.active_peer_count ());
          "live_connections", `Int (Server_webrtc_transport.live_webrtc_count ());
          "connected_channels", `Int (Server_webrtc_transport.connected_channel_count ());
        ]
        let reap_stale () = 0  (* WebRTC has its own ICE timeout *)
      end);
      Transport_bridge.seal ();
      (* Cold-start warm-cache stagger is handled by warm_delay_s in each
         Proactive_refresh config. Heavy surfaces delay their initial warm
         compute to avoid concurrent CPU/PG contention.  Lightweight surfaces
         (cp-summary, execution, transport_health) start immediately. *)
      Server_command_plane_http_support.start_cp_summary_refresh_loop ~state ~sw ~clock;
      Server_command_plane_http_support.start_cp_snapshot_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_execution_refresh_loop ~state ~sw ~clock ~net ~mono_clock;
      Server_dashboard_http.start_transport_health_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_mission_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_operator_snapshot_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_operator_digest_refresh_loop ~state ~sw ~clock;
      (* Pre-warm shell cache in a separate fiber so it cannot block
         keeper loop startup or lazy tasks (#keeper-bootstrap-stuck). *)
      Eio.Fiber.fork ~sw (fun () ->
        (try
           match Eio.Time.with_timeout clock 10.0 (fun () ->
             Server_dashboard_http.warm_shell_cache state;
             Ok ())
           with
           | Ok () -> ()
           | Error `Timeout ->
             Log.Dashboard.warn "shell cache pre-warm timed out (10s)"
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Dashboard.warn "shell cache pre-warm failed: %s"
             (Printexc.to_string exn)));
      Server_bootstrap_loops.start_keeper_loops ~sw ~clock ~net ~domain_mgr ~proc_mgr state;
      start_lazy_startup state
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Server_startup_state.mark_degraded ~error:(Printexc.to_string exn);
      Log.Server.error "Background init failed (HTTP still serving): %s"
        (Printexc.to_string exn);
      if String.equal initial_backend_mode "postgres-native" then
        exit 1);

  (* 2b. Startup watchdog: if init does not reach state_ready within timeout,
     log and exit so external process managers can restart the server.
     Prevents zombie-listener state where the socket is open but HTTP
     requests hang because init is stuck. *)
  Eio.Fiber.fork ~sw (fun () ->
    try
      let timeout_sec = Server_startup_state.watchdog_timeout_sec () in
      Eio.Time.sleep clock timeout_sec;
      let current = Server_startup_state.(!state) in
      if not current.state_ready then (
        let elapsed = Server_startup_state.elapsed_since_start () in
        Log.Server.error
          "[watchdog] Server init did not complete within %.0fs (elapsed=%.1fs, phase=%s, backend=%s). Exiting."
          timeout_sec elapsed
          (Server_startup_state.phase_to_string current.phase)
          current.backend_mode;
        exit 1)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.error "startup watchdog fiber failed: %s"
        (Printexc.to_string exn));

  (* 3. Start serving -- /health responds before init completes *)
  match http_mode with
  | `H2_only ->
    Server_bootstrap_http.serve_h2 ~sw ~clock ~socket ~h2_request_handler ~h2_error_handler
  | `H1_only ->
    Server_bootstrap_http.serve ~sw ~clock ~socket ~request_handler
  | `Auto ->
    Server_bootstrap_http.serve_auto ~sw ~clock ~socket ~request_handler ~h2_request_handler
      ~h2_error_handler
