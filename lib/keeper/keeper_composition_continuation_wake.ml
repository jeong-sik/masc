module Journal = Keeper_tool_execution_journal
module Snapshot = Skill_catalog_snapshot_service
let ( let* ) = Result.bind

type error =
  | Profile_unavailable of Keeper_types_profile.keeper_toml_load_error
  | Metadata_unavailable of Keeper_meta_store.current_meta_rejection
  | Metadata_missing
  | Metadata_owner_mismatch
  | Profile_rejected of string
  | Keeper_paused
  | Snapshot_lookup_failed of Config_dir_resolver.canonical_base_path_error
  | Snapshot_missing
  | Snapshot_rejected of Skill_catalog_snapshot.config_state
  | Runtime_failed of string
  | Original_activation_unavailable of Keeper_composition_draft.error
  | Original_task_skills_unavailable of Keeper_task_skill_turn.error

type recovery_hold =
  | Original_run_unavailable of Keeper_composition_draft.error
  | Task_skill_publication_unavailable of
      { error : Keeper_task_skill_turn.error
      ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
      }
  | Explicit_recovery_required of string

let recovery_hold_to_string = function
  | Original_run_unavailable error ->
    Yojson.Safe.to_string (Keeper_composition_draft.error_to_json error)
  | Task_skill_publication_unavailable {error; snapshot_revision=_} ->
    Keeper_task_skill_turn.error_to_string error
  | Explicit_recovery_required detail -> detail

let recovery_hold_kind = function
  | Original_run_unavailable _ -> "waiting_original_run"
  | Task_skill_publication_unavailable _ -> "waiting_skill_publication"
  | Explicit_recovery_required _ -> "explicit_recovery_required"

let error_to_string = function
  | Profile_unavailable error -> Keeper_types_profile.keeper_toml_load_error_to_string error
  | Metadata_unavailable (Unreadable detail | Not_current detail) -> detail
  | Metadata_missing -> "original Keeper metadata is missing"
  | Metadata_owner_mismatch -> "metadata does not belong to the original Keeper"
  | Profile_rejected detail | Runtime_failed detail -> detail
  | Original_activation_unavailable error -> Yojson.Safe.to_string (Keeper_composition_draft.error_to_json error)
  | Original_task_skills_unavailable error -> Keeper_task_skill_turn.error_to_string error
  | Keeper_paused -> "original Keeper is paused"
  | Snapshot_lookup_failed error -> Config_dir_resolver.canonical_base_path_error_to_string error
  | Snapshot_missing -> "current workspace Skill snapshot is unavailable"
  | Snapshot_rejected state -> Skill_catalog_snapshot.config_state_to_string state

let current_snapshot ~base_path =
  let* workspace = Snapshot.find_workspace_of_base_path ~base_path
    |> Result.map_error (fun error -> Snapshot_lookup_failed error) in
  let* snapshot = match workspace with
    | None -> Error Snapshot_missing
    | Some workspace -> (match Snapshot.current ~workspace with
      | Some snapshot -> Ok snapshot | None -> Error Snapshot_missing) in
  match Skill_catalog_snapshot.config_state snapshot with
  | Configured _ -> Ok snapshot
  | (Config_rejected _ | Config_unreadable _) as state -> Error (Snapshot_rejected state)

let read_profiles ~base_path =
  Domain_pool_ref.submit_io_or_inline (fun () ->
    Keeper_types_profile.read_keeper_profile_snapshot ~base_path)

let resume_with_profiles ?on_recovery_held ~profiles ~context continuation =
  let source = Journal.continuation_source continuation in
  let hold_original cause error =
    Option.iter (fun observe ->
      observe ~request_id:(Journal.continuation_request_id continuation)
        ~cause) on_recovery_held;
    error in
  let config = context.Keeper_types_profile.config in
  let* defaults = Keeper_types_profile.snapshot_profile_defaults profiles source.keeper_name
    |> Result.map_error (fun error -> Profile_unavailable error) in
  (* The ordinary metadata path helper creates the directory. This uses the
     same canonical path components for a strict read without that effect. *)
  let metadata_path = Filename.concat (Workspace.keepers_runtime_dir config)
      (Keeper_runtime_root_entry.keeper_basename ~keeper_name:source.keeper_name Metadata) in
  let* persisted = Keeper_meta_store.read_meta_file_path_read_only
      ~ownership_root:config.base_path metadata_path
    |> Result.map_error (fun error -> Metadata_unavailable error) in
  let* meta, owner_metadata_refusal =
    match persisted with
    | Some persisted when persisted.name = source.keeper_name ->
      let* meta = Keeper_meta_contract.effective_meta_of_profile_defaults defaults persisted
        |> Result.map_error (fun detail -> Profile_rejected detail) in
      Ok (meta, None)
    | None | Some _ ->
      let refusal = match persisted with
        | None -> Keeper_tool_composition_surface.Owner_metadata_missing
        | Some _ -> Keeper_tool_composition_surface.Owner_metadata_mismatch in
      let* trace_id =
        match source.producer with
        | Journal.Named {activation=Some bound;_} ->
          Ok (Keeper_skill_activation_recorder.bound_trace_id bound)
        | Journal.Prepared | Journal.Named {activation=None;_} ->
          Keeper_id.Trace_id.of_string ("refusal-" ^ source.keeper_name)
          |> Result.map_error (fun detail -> Runtime_failed ("refusal trace identity rejected: " ^ detail)) in
      let placeholder : Keeper_meta_contract.keeper_meta =
        { id = None; name = source.keeper_name; instructions = ""
        ; sandbox_profile = Keeper_types_profile.Docker; sandbox_image = None
        ; network_mode = Keeper_types_profile.Network_none; microvm_backend = None
        ; microvm_memory = None; microvm_cpus = None; mention_targets = []
        ; board_interests = []; created_at = ""; updated_at = ""
        ; max_context_override = None; paused = false; latched_reason = None
        ; input_policy = Keeper_input_policy.default
        ; activation_mode = Keeper_activation_mode.default; current_task_id = None
        ; telemetry_feedback_enabled = None; telemetry_feedback_window_hours = None
        ; always_allow = None; voice_always_allow = None
        ; runtime =
            { usage =
                { total_turns = 0; total_input_tokens = 0; total_output_tokens = 0
                ; total_tokens = 0; total_cost_usd = Keeper_cost_coverage.empty; last_turn_ts = 0.0
                ; last_input_tokens = 0; last_output_tokens = 0; last_total_tokens = 0
                ; last_usage_reported_at = None; last_latency_ms = 0 }
            ; usage_cursor = None; last_usage_resolution = None
            ; proactive_rt =
                { count_total = 0; last_ts = 0.0; visible_count_total = 0
                ; last_visible_ts = 0.0
                ; last_outcome = Keeper_meta_contract.Proactive_never_started
                ; last_reason = ""; last_preview = "" }
            ; trace_id; last_runtime_attempt = None; message_scope_ack_id = None }
        ; keeper_id = None; agent_core_env = [] } in
      let* meta = Keeper_meta_contract.effective_meta_of_profile_defaults defaults placeholder
        |> Result.map_error (fun detail -> Profile_rejected detail) in
      Ok (meta, Some refusal)
  in
  let* () = if meta.paused then Error Keeper_paused else Ok () in
  let* snapshot = current_snapshot ~base_path:config.base_path in
  let* nested_activation = Keeper_composition_draft.load_nested_activation ~base_path:config.base_path source
    |> Result.map_error (fun error -> hold_original (Original_run_unavailable error)
        (Original_activation_unavailable error)) in
  let addons = Keeper_lane_addon_runtime.snapshot ~config ~keeper_name:source.keeper_name in
  let descriptors = Keeper_tool_descriptor.all_descriptors ()
    @ List.map Keeper_lane_addon_descriptor.create addons.exports in
  let original_activation = match source.producer with
    | Journal.Prepared -> nested_activation
    | Journal.Named {activation;tool_name=_;skill_reference=_;origin=_} -> activation in
  let hold_task_skills error = hold_original
      (Task_skill_publication_unavailable
         {error; snapshot_revision=Skill_catalog_snapshot.snapshot_revision snapshot})
      (Original_task_skills_unavailable error) in
  let task_references = match original_activation with
    | None -> []
    | Some bound -> Keeper_skill_activation_recorder.bound_task_references bound in
  let* (task_selection,preparation) = Keeper_task_skill_turn.resolve_surface
      ~descriptors ~snapshot task_references
    |> Result.map_error hold_task_skills in
  List.iter (fun (diagnostic : Keeper_skill_catalog.projection_diagnostic) ->
    Log.Keeper.warn ~keeper_name:source.keeper_name "continuation Skill projection unavailable: %s"
      (Keeper_skill_catalog.error_to_string diagnostic.error)) preparation.diagnostics;
  let capability_surface = Keeper_capability_surface.create_with_descriptors
      ~tool_descriptors:descriptors ~tool_deny:defaults.tool_deny ~sandbox_profile:meta.sandbox_profile
      ~skill_names:defaults.skill_names ~global_skill_catalog:preparation.catalog
      ~skill_inventory:preparation.inventory
      ~task_skills:(Keeper_task_skill_turn.skills task_selection) in
  let cell = Keeper_tool_call_log_context.create_cell () in
  Keeper_tool_call_log_context.set_turn_context ~cell ~agent_name:source.keeper_name
    ?task_id:source.source_task_id ~turn:source.source_turn
    ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ();
  let turn_context = Keeper_tool_call_log_context.get_turn_context_record ~cell () in
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:source.parent_tool_use_id
      ~turn:source.source_turn ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Concurrent}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  let publication_recovery : Keeper_publication_recovery_availability.turn_context =
    {provider=context.publication_recovery_provider;keeper_name=source.keeper_name} in
  let on_execution_held = Option.map (fun observe ~request_id ~reason ->
      observe ~request_id ~cause:(Explicit_recovery_required reason)) on_recovery_held in
  Ok (Keeper_tool_composition_surface.resume_continuation ?on_recovery_held:on_execution_held ?owner_metadata_refusal ~capability_surface ~continuation
      ~config ~meta ~publication_recovery
      ~ctx_snapshot:(Keeper_context_runtime.create ~eio:true ~system_prompt:meta.instructions)
      ~turn_context ~invocation
      ~clock:(context.clock :> float Eio.Time.clock_ty Eio.Resource.t) ())

let resume ?on_recovery_held ~context continuation =
  let profiles = read_profiles ~base_path:context.Keeper_types_profile.config.base_path in
  resume_with_profiles ?on_recovery_held ~profiles ~context continuation

module Run_key = struct
  type t = string * Keeper_tool_plan.Composition_run_id.t
  let compare (left_keeper,left_run) (right_keeper,right_run) =
    let keeper = String.compare left_keeper right_keeper in
    if keeper <> 0 then keeper else String.compare
      (Keeper_tool_plan.Composition_run_id.to_string left_run)
      (Keeper_tool_plan.Composition_run_id.to_string right_run)
end
module Run_set = Set.Make (Run_key)
module Run_map = Map.Make (Run_key)

type held_recovery = { request_id : string; cause : recovery_hold }

type recovery_readiness =
  | Continue_holding of recovery_hold
  | Revalidate_original

let recovery_readiness ~base_path candidate cause =
  match cause with
  | Original_run_unavailable _ ->
    (match Domain_pool_ref.submit_io_or_inline (fun () ->
       Keeper_composition_draft.load_nested_activation ~base_path
         (Journal.continuation_source candidate)) with
     | Ok _ -> Revalidate_original
     | Error error -> Continue_holding (Original_run_unavailable error))
  | Task_skill_publication_unavailable {error=_; snapshot_revision} ->
    (match current_snapshot ~base_path with
     | Ok snapshot when not (Skill_catalog_snapshot.equal_snapshot_revision
         snapshot_revision (Skill_catalog_snapshot.snapshot_revision snapshot)) -> Revalidate_original
     | Ok _ | Error _ -> Continue_holding cause)
  | Explicit_recovery_required _ -> Continue_holding cause

type discovery_trigger = Maintenance | Result_ready
type discovery_boundary = Discovery_unfinished | Discovery_drained | Discovery_cancelled | Discovery_raised
type discovery_drain =
  { mutable follow_up : bool
  ; mutable notifications : int
  ; mutable maintenance_pulses : int
  ; mutable discovery_started : int
  ; mutable discovery_settled : int
  ; mutable discovery_errors : int
  ; mutable discovery_raised : int
  ; mutable boundary : discovery_boundary }

type 'a t =
  { context : 'a Keeper_types_profile.context
  ; on_result : Journal.continuation -> (Tool_result.result,error) result -> unit
  ; on_discovery : base_path:string -> (unit,Journal.error) result -> unit
  ; mutable active : Run_set.t
  ; mutable held : held_recovery Run_map.t
  ; mutable discovery : discovery_drain option }


let log_result ~base_path candidate outcome =
  let source = Journal.continuation_source candidate in
  let run_id = Keeper_tool_plan.Composition_run_id.to_string source.composition_run_id in
  match outcome with
  | Error error -> Log.Keeper.warn ~keeper_name:source.keeper_name
      "prepared continuation retained run=%s error=%s base_path=%S" run_id (error_to_string error) base_path
  | Ok result ->
    let state = match result with
      | Tool_result.Completed _ -> "accepted"
      | Deferred _ -> "waiting"
      | Failed _ -> "refused" in
    Log.Keeper.info ~keeper_name:source.keeper_name "prepared continuation intake run=%s state=%s base_path=%S" run_id state base_path

let log_discovery ~base_path = function
  | Ok () -> ()
  | Error error -> Log.Server.warn "prepared continuation discovery unavailable: %s base_path=%S"
      (Journal.error_to_string error) base_path

let create ~(context : 'a Keeper_types_profile.context) ?(on_result=log_result ~base_path:context.config.base_path) ?(on_discovery=log_discovery) () =
  {context;on_result;on_discovery;active=Run_set.empty;held=Run_map.empty;discovery=None}

let discover_and_schedule ~resume ~sw supervisor =
  Eio.Switch.check sw;
  (* One immutable declaration projection belongs to this pulse, never to the
     supervisor. Eio.Lazy shares in-flight I/O and restarts a cancelled read for
     a remaining caller. No eligible intake means no declaration filesystem I/O. *)
  let profiles = Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
    read_profiles ~base_path:supervisor.context.config.base_path) in
  let on_ready candidate =
    let source = Journal.continuation_source candidate in
    let key = source.keeper_name,source.composition_run_id in
    let held = match Run_map.find_opt key supervisor.held with
      | Some held when String.equal held.request_id (Journal.continuation_request_id candidate) -> Some held
      | None -> None
      | Some _ -> supervisor.held <- Run_map.remove key supervisor.held; None in
    let explicit_recovery = match held with
      | Some {cause=Explicit_recovery_required _; _} -> true
      | None | Some {cause=(Original_run_unavailable _ | Task_skill_publication_unavailable _); _} -> false in
    if not explicit_recovery && not (Run_set.mem key supervisor.active) then (
      Eio.Switch.check sw;
      (* Single-domain reservation is a scheduling hint, never effect authority. *)
      supervisor.active <- Run_set.add key supervisor.active;
      try Eio.Fiber.fork ~sw (fun () ->
        let outcome = Fun.protect
            ~finally:(fun () -> supervisor.active <- Run_set.remove key supervisor.active)
            (fun () ->
              (* Return fork control before evidence/profile I/O. The original
                 finally also releases a child cancelled at this entry point. *)
              Eio.Fiber.yield ();
              let on_recovery_held ~request_id ~cause =
                supervisor.held <- Run_map.add key {request_id; cause} supervisor.held;
                Log.Keeper.warn ~keeper_name:source.keeper_name
                  "prepared continuation held run=%s request=%s state=%s reason=%s"
                  (Keeper_tool_plan.Composition_run_id.to_string source.composition_run_id) request_id
                  (recovery_hold_kind cause) (recovery_hold_to_string cause) in
              try
                let readiness = match held with
                  | None -> Revalidate_original
                  | Some held -> recovery_readiness ~base_path:supervisor.context.config.base_path
                      candidate held.cause in
                match readiness with
                | Continue_holding cause ->
                  supervisor.held <- Run_map.add key
                    {request_id=Journal.continuation_request_id candidate; cause} supervisor.held;
                  None
                | Revalidate_original ->
                  Option.iter (fun _ ->
                    supervisor.held <- Run_map.remove key supervisor.held;
                    Log.Keeper.info ~keeper_name:source.keeper_name
                      "prepared continuation evidence changed run=%s request=%s; revalidating original authority"
                      (Keeper_tool_plan.Composition_run_id.to_string source.composition_run_id)
                      (Journal.continuation_request_id candidate)) held;
                  let profiles = Eio.Lazy.force profiles in
                  Some (resume ~on_recovery_held ~profiles ~context:supervisor.context candidate)
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn -> Some (Error (Runtime_failed (Printexc.to_string exn)))) in

        Option.iter (fun outcome ->
          try supervisor.on_result candidate outcome with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Log.Server.warn "prepared continuation observer failed: %s base_path=%S" (Printexc.to_string exn) supervisor.context.config.base_path) outcome)
      with exn ->
        supervisor.active <- Run_set.remove key supervisor.active;
        raise exn) in
  let* pending = Journal.discover_pending_continuations ~on_ready
      ~read_composition_result:Keeper_composition_dependency_result.readiness
      ~base_path:supervisor.context.config.base_path in
  List.iter (fun (identity,error) -> Log.Server.warn "prepared continuation discovery retained request=%s error=%s base_path=%S"
      identity (Journal.error_to_string error) supervisor.context.config.base_path) pending.failures;
  Ok ()

type discovery_phase =
  | Reserved | Started | Settled of (unit,Journal.error) result | Interrupted | Raised

let observe_discovery ~base_path ~reserved_ns request phase =
  let emit () = try Log.Server.routine_lazy (fun () ->
      let phase,detail = match phase with
        | Reserved -> "reserved", ""
        | Started -> "started", ""
        | Settled result -> "settled",
            (match result with Ok () -> " outcome=returned" | Error _ -> " outcome=failed")
        | Interrupted -> "interrupted", ""
        | Raised -> "raised", "" in
      Printf.sprintf "prepared_continuation_discovery reserved_ns=%Ld pass=%d phase=%s at_ns=%Ld%s base_path=%S"
        reserved_ns request.discovery_started phase (Mtime_clock.elapsed_ns ()) detail base_path)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> () in
  Eio.Cancel.protect emit

let request_discovery ~trigger ~resume ~sw supervisor =
  (* [fork] can decline a cancelled switch without entering its callback.
     Do not reserve a discovery owner that has no worker to release it. *)
  Eio.Switch.check sw;
  let record_demand request =
    (match trigger with
     | Maintenance -> request.maintenance_pulses <- request.maintenance_pulses + 1
     | Result_ready -> request.notifications <- request.notifications + 1);
    request.follow_up <- true in
  match supervisor.discovery with
  | Some request ->
    record_demand request
  | None ->
    let request = {follow_up=false;notifications=0;maintenance_pulses=0;discovery_started=0;
      discovery_settled=0;discovery_errors=0;discovery_raised=0;boundary=Discovery_unfinished} in
    record_demand request;
    supervisor.discovery <- Some request;
    let base_path = supervisor.context.config.base_path in
    let reserved_ns = Mtime_clock.elapsed_ns () in
    let observe = observe_discovery ~base_path ~reserved_ns request in
    let release () = match supervisor.discovery with
      | Some current when current == request -> supervisor.discovery <- None
      | Some _ | None -> () in
    let log_boundary () =
      let emit () = try
        let boundary = match request.boundary with
          | Discovery_unfinished -> "unfinished" | Discovery_drained -> "drained"
          | Discovery_cancelled -> "cancelled" | Discovery_raised -> "raised" in
        Log.Server.debug
          "prepared_continuation_discovery_drain boundary=%s maintenance=%d notifications=%d discovery_started=%d discovery_settled=%d discovery_errors=%d discovery_raised=%d follow_up=%b base_path=%S"
          boundary request.maintenance_pulses request.notifications request.discovery_started
          request.discovery_settled request.discovery_errors request.discovery_raised request.follow_up base_path
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | _ -> () in
      Eio.Cancel.protect emit in
    let rec drain () =
      (* Consume only the demand that preceded this read. A durable result
         arriving while it yields must survive for a fresh subsequent pulse. *)
      request.follow_up <- false;
      request.discovery_started <- request.discovery_started + 1;
      observe Started;
      let returned =
        try Some (discover_and_schedule ~resume ~sw supervisor) with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            request.discovery_raised <- request.discovery_raised + 1;
            observe Raised;
            Log.Server.warn "prepared continuation discovery raised: %s base_path=%S" (Printexc.to_string exn) base_path;
            None in
      Option.iter (fun result ->
        request.discovery_settled <- request.discovery_settled + 1;
        (match result with Ok () -> () | Error _ ->
          request.discovery_errors <- request.discovery_errors + 1);
        observe (Settled result);
        try supervisor.on_discovery ~base_path result with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Log.Server.warn "prepared continuation discovery observer failed: %s base_path=%S"
            (Printexc.to_string exn) base_path) returned;
      if request.follow_up then drain () in
    (try
       observe Reserved;
       Eio.Switch.check sw;
       Eio.Fiber.fork ~sw (fun () ->
       match Fun.protect ~finally:release (fun () ->
         (* Even an inline filesystem implementation must not put discovery
            in the durable result producer's acknowledgement path. *)
         try
           Eio.Fiber.yield ();
           drain ();
           request.boundary <- Discovery_drained
         with
         | Eio.Cancel.Cancelled _ as exn ->
             request.boundary <- Discovery_cancelled; observe Interrupted; raise exn
         | exn ->
           let backtrace = Printexc.get_raw_backtrace () in
           request.boundary <- Discovery_raised;
           observe Raised;
           Printexc.raise_with_backtrace exn backtrace) with
       | () -> log_boundary ()
       | exception exn ->
           let backtrace = Printexc.get_raw_backtrace () in
           log_boundary ();
           Printexc.raise_with_backtrace exn backtrace)
     with
     | Eio.Cancel.Cancelled _ as exn ->
         request.boundary <- Discovery_cancelled; release (); log_boundary (); raise exn
     | exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       request.boundary <- Discovery_raised;
       release ();
       log_boundary ();
       Printexc.raise_with_backtrace exn backtrace)

let pulse ~sw supervisor =
  request_discovery ~trigger:Maintenance ~resume:(fun ~on_recovery_held ~profiles ~context candidate ->
    resume_with_profiles ~on_recovery_held ~profiles ~context candidate) ~sw supervisor

let notify_result_ready ~sw supervisor =
  request_discovery ~trigger:Result_ready ~resume:(fun ~on_recovery_held ~profiles ~context candidate ->
    resume_with_profiles ~on_recovery_held ~profiles ~context candidate) ~sw supervisor

module For_testing = struct
  let notify_result_ready ~resume ~sw supervisor =
    request_discovery ~trigger:Result_ready ~resume ~sw supervisor
  let pulse ~resume ~sw supervisor =
    request_discovery ~trigger:Maintenance ~resume ~sw supervisor
end
