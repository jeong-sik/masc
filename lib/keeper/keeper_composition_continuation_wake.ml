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

let error_to_string = function
  | Profile_unavailable error -> Keeper_types_profile.keeper_toml_load_error_to_string error
  | Metadata_unavailable (Unreadable detail | Not_current detail) -> detail
  | Metadata_missing -> "original Keeper metadata is missing"
  | Metadata_owner_mismatch -> "metadata does not belong to the original Keeper"
  | Profile_rejected detail | Runtime_failed detail -> detail
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

let resume ~context continuation =
  let source = Journal.continuation_source continuation in
  let config = context.Keeper_types_profile.config in
  let profiles = Keeper_types_profile.read_keeper_profile_snapshot ~base_path:config.base_path in
  let* defaults = Keeper_types_profile.snapshot_profile_defaults profiles source.keeper_name
    |> Result.map_error (fun error -> Profile_unavailable error) in
  (* The ordinary metadata path helper creates the directory. This uses the
     same canonical path components for a strict read without that effect. *)
  let metadata_path = Filename.concat (Workspace.keepers_runtime_dir config)
      (Keeper_runtime_root_entry.keeper_basename ~keeper_name:source.keeper_name Metadata) in
  let* persisted = Keeper_meta_store.read_meta_file_path_read_only
      ~ownership_root:config.base_path metadata_path
    |> Result.map_error (fun error -> Metadata_unavailable error) in
  let* persisted = match persisted with Some meta -> Ok meta | None -> Error Metadata_missing in
  let* () = if persisted.name = source.keeper_name then Ok () else Error Metadata_owner_mismatch in
  let* meta = Keeper_meta_contract.effective_meta_of_profile_defaults defaults persisted
    |> Result.map_error (fun detail -> Profile_rejected detail) in
  let* () = if meta.paused then Error Keeper_paused else Ok () in
  let* snapshot = current_snapshot ~base_path:config.base_path in
  let addons = Keeper_lane_addon_runtime.snapshot ~config ~keeper_name:source.keeper_name in
  let descriptors = Keeper_tool_descriptor.all_descriptors ()
    @ List.map Keeper_lane_addon_descriptor.create addons.exports in
  let catalog,diagnostics = Keeper_skill_catalog.of_snapshot ~descriptors snapshot in
  List.iter (fun (diagnostic : Keeper_skill_catalog.projection_diagnostic) ->
    Log.Keeper.warn ~keeper_name:source.keeper_name "continuation Skill projection unavailable: %s"
      (Keeper_skill_catalog.error_to_string diagnostic.error)) diagnostics;
  (* Prepared async recipes have ordinary leaves, not named/nested Skills.
     Their original recipe is compiled by the sealed intake below. *)
  let capability_surface = Keeper_capability_surface.create_with_descriptors
      ~tool_descriptors:descriptors ~tool_deny:defaults.tool_deny ~sandbox_profile:meta.sandbox_profile
      ~skill_names:defaults.skill_names ~global_skill_catalog:catalog
      ~skill_inventory:(Keeper_skill_inventory.of_snapshot ~descriptors snapshot) ~task_skills:[] in
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
  Ok (Keeper_tool_composition_surface.resume_continuation ~capability_surface ~continuation
      ~config ~meta ~publication_recovery
      ~ctx_snapshot:(Keeper_context_runtime.create ~eio:true ~system_prompt:meta.instructions)
      ~turn_context ~invocation
      ~clock:(context.clock :> float Eio.Time.clock_ty Eio.Resource.t) ())

module Run_set = Set.Make (struct
  type t = string * Keeper_tool_plan.Composition_run_id.t
  let compare (left_keeper,left_run) (right_keeper,right_run) =
    let keeper = String.compare left_keeper right_keeper in
    if keeper <> 0 then keeper else String.compare
      (Keeper_tool_plan.Composition_run_id.to_string left_run)
      (Keeper_tool_plan.Composition_run_id.to_string right_run)
end)
type 'a t =
  { context : 'a Keeper_types_profile.context
  ; on_result : Journal.continuation -> (Tool_result.result,error) result -> unit
  ; mutable active : Run_set.t }

(** A refusal that cannot heal by retrying: the sealed run's tool contract was
    rejected by current authority ([Policy_rejection], e.g. the capability
    surface changed) or the run's durable ownership no longer admits it
    ([Workflow_rejection], e.g. source conflict or ownership change), or the
    original Keeper's metadata is gone or belongs to another Keeper.
    Transient outcomes — paused Keeper, missing snapshot, unavailable
    profile/metadata, runtime faults — stay retryable and are never listed
    here. *)
type permanent_refusal =
  | Owner_metadata_missing
  | Owner_metadata_mismatch
  | Sealed_run_refused of Tool_result.failure_payload

let permanent_refusal_of_outcome (outcome : (Tool_result.result, error) result) =
  match outcome with
  | Error error ->
    (match error with
     | Metadata_missing -> Some Owner_metadata_missing
     | Metadata_owner_mismatch -> Some Owner_metadata_mismatch
     | Profile_unavailable _ | Metadata_unavailable _ | Profile_rejected _
     | Keeper_paused | Snapshot_lookup_failed _ | Snapshot_missing
     | Snapshot_rejected _ | Runtime_failed _ -> None)
  | Ok result ->
    match result with
    | Tool_result.Failed failure ->
      (match failure.class_ with
       | Tool_result.Policy_rejection | Tool_result.Workflow_rejection ->
         Some (Sealed_run_refused failure)
       | Tool_result.Dependency_unavailable | Tool_result.Runtime_failure
       | Tool_result.Operator_cancelled -> None)
    | Tool_result.Completed _ | Tool_result.Deferred _ -> None

let refusal_message = function
  | Owner_metadata_missing -> error_to_string Metadata_missing
  | Owner_metadata_mismatch -> error_to_string Metadata_owner_mismatch
  | Sealed_run_refused failure -> failure.message

let refusal_data = function
  | Owner_metadata_missing -> `Assoc ["kind", `String "owner_metadata_missing"]
  | Owner_metadata_mismatch -> `Assoc ["kind", `String "owner_metadata_mismatch"]
  | Sealed_run_refused failure -> Tool_result.data (Tool_result.Failed failure)

let settle_permanent_refusal supervisor candidate refusal =
  let source = Journal.continuation_source candidate in
  let base_path = supervisor.context.config.base_path in
  let request_id = Journal.continuation_request_id candidate in
  let run_id = Keeper_tool_plan.Composition_run_id.to_string source.composition_run_id in
  match
    Keeper_composition_completion_outbox.prepare_terminal
      ~base_path ~keeper_name:source.keeper_name ~request_id
  with
  | Error error ->
    Log.Keeper.warn ~keeper_name:source.keeper_name
      "prepared continuation refusal delivery retained run=%s request=%s error=%s"
      run_id request_id (Keeper_composition_completion_outbox.error_to_string error)
  | Ok () ->
    (match
       Keeper_msg_async.settle_waiting_request_as_failed ~base_path ~caller:source.keeper_name
         ~request_id ~body:(refusal_message refusal) ~data:(refusal_data refusal)
         ~before_persist:(fun _ ->
           Keeper_composition_completion_outbox.prepare_terminal
             ~base_path ~keeper_name:source.keeper_name ~request_id
           |> Result.map_error Keeper_composition_completion_outbox.error_to_string)
         ()
     with
     | Error error ->
       (* The delivery obligation stays pending; while the canonical record
          remains waiting, the outbox retires it without delivering, and the
          next pulse retries this refusal end to end. *)
       Log.Keeper.warn ~keeper_name:source.keeper_name
         "prepared continuation refusal settlement retained run=%s request=%s error=%s"
         run_id request_id (Keeper_msg_async.waiting_settlement_rejection_to_string error)
     | Ok () ->
       Log.Keeper.info ~keeper_name:source.keeper_name
         "prepared continuation refused permanently run=%s request=%s; failure terminal settled and delivery obligated"
         run_id request_id)

let log_result candidate outcome =
  let source = Journal.continuation_source candidate in
  let run_id = Keeper_tool_plan.Composition_run_id.to_string source.composition_run_id in
  match outcome with
  | Error error -> Log.Keeper.warn ~keeper_name:source.keeper_name
      "prepared continuation retained run=%s error=%s" run_id (error_to_string error)
  | Ok result ->
    let state = match result with
      | Tool_result.Completed _ -> "accepted"
      | Deferred _ -> "waiting"
      | Failed _ -> "refused" in
    Log.Keeper.info ~keeper_name:source.keeper_name "prepared continuation intake run=%s state=%s" run_id state

let create ~context ?(on_result=log_result) () = {context;on_result;active=Run_set.empty}

let pulse ~sw supervisor =
  let* pending = Journal.pending_continuations ~base_path:supervisor.context.config.base_path in
  List.iter (fun (identity,error) -> Log.Server.warn "prepared continuation discovery retained request=%s error=%s"
      identity (Journal.error_to_string error)) pending.failures;
  List.iter (fun candidate ->
    let source = Journal.continuation_source candidate in
    let key = source.keeper_name,source.composition_run_id in
    if not (Run_set.mem key supervisor.active) then (
      (* Single-domain reservation is a scheduling hint, never effect authority. *)
      supervisor.active <- Run_set.add key supervisor.active;
      try Eio.Fiber.fork ~sw (fun () ->
        let outcome = Fun.protect
            ~finally:(fun () -> supervisor.active <- Run_set.remove key supervisor.active)
            (fun () ->
              try resume ~context:supervisor.context candidate with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn -> Error (Runtime_failed (Printexc.to_string exn))) in
        (match permanent_refusal_of_outcome outcome with
         | Some refusal ->
           (try settle_permanent_refusal supervisor candidate refusal with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn -> Log.Server.warn "prepared continuation refusal settle failed: %s" (Printexc.to_string exn))
         | None -> ());
        (try supervisor.on_result candidate outcome with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn -> Log.Server.warn "prepared continuation observer failed: %s" (Printexc.to_string exn)))
      with exn ->
        supervisor.active <- Run_set.remove key supervisor.active;
        raise exn)) pending.ready;
  Ok ()
