module Catalog = Keeper_tool_composition_catalog
module Journal = Keeper_tool_execution_journal
open Keeper_tool_composition_surface_schema
open Keeper_tool_composition_surface_execution
open Keeper_tool_composition_surface_outcome
open Keeper_tool_composition_surface_async

let resume_continuation_with ?on_recovery_held ?owner_metadata_refusal ?on_refusal_accepted ?observe_refusal_settlement
    ~capability_surface ~continuation ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) ~publication_recovery ~ctx_snapshot
    ~(turn_context : Keeper_tool_call_log_context.turn_context) ~invocation ?clock () =
  let module Draft = Keeper_composition_draft in
  let source = Journal.continuation_source continuation in
  let tool_name,skill_reference = match source.producer with
    | Journal.Prepared -> Draft.run_tool_name,None
    | Journal.Named {tool_name;skill_reference;activation=_;origin=_} -> tool_name,Some skill_reference in
  let start_time = Tool_timing.start () in
  let hold reason = Option.iter (fun observe ->
      observe ~request_id:(Journal.continuation_request_id continuation) ~reason) on_recovery_held in
  let refuse_original_draft error =
    let detail = Yojson.Safe.to_string (Draft.error_to_json error) in
    hold detail;
    Tool_result.make_err ~tool_name
      ~class_:(Draft.failure_class error) ~effect_disposition:Tool_result.Proven_pre_effect
      ~start_time ~data:(Draft.error_to_json error) detail in
  let refuse_journal error =
    hold (Journal.error_to_string error);
    Tool_result.make_err ~tool_name
      ~class_:(Journal.failure_class error) ~effect_disposition:Tool_result.Proven_pre_effect
      ~start_time ~data:(Journal.error_to_json error) (Journal.error_to_string error) in
  if meta.name <> source.keeper_name
      || publication_recovery.Keeper_publication_recovery_availability.keeper_name <> source.keeper_name
  then refuse_journal Journal.Source_conflict else
  let producer_admitted = match skill_reference with
    | None -> true
    | Some reference -> Keeper_skill_catalog.skills
        (Keeper_capability_surface.skill_projection capability_surface).catalog
        |> List.exists (fun (skill : Keeper_skill_catalog.skill) ->
          Option.exists (Skill_reference.equal reference) skill.reference &&
          match skill.surface with
          | Composition entry -> entry.execution = Catalog.Async && String.equal (Catalog.tool_name entry) tool_name
          | Instruction -> false) in
  match Draft.load_continuation_admission ~base_path:config.base_path ~capability_surface continuation with
  | Error error -> refuse_original_draft error
  | Ok admission ->
    let draft,refusal = match admission with
      | Draft.Admitted draft -> draft,None
      | Draft.Refused (draft,refusal) -> draft,Some (Current_leaf_denied refusal) in
    let nested_activation = Keeper_composition_draft.load_nested_activation ~base_path:config.base_path source in
    (match nested_activation with
    | Error error -> refuse_original_draft error
    | Ok nested_activation ->
    match Journal.continuation_readiness ~read_composition_result:Keeper_composition_dependency_result.readiness continuation with
    | Error error -> refuse_journal error
    | Ok Journal.Waiting_for_results ->
      Tool_result.make_deferred ~tool_name ~start_time
        ~data:(`Assoc ["kind",`String "waiting_for_original_results";
          "composition_run_id",`String (Keeper_tool_plan.Composition_run_id.to_string source.composition_run_id);
          "dependencies",`List (List.map Keeper_composition_dependency.to_json
            (Journal.continuation_dependencies continuation))]) ()
    | Ok Journal.Results_ready ->
      match Journal.load ~base_path:config.base_path ~keeper_name:source.keeper_name
          ~composition_run_id:source.composition_run_id with
      | Error error -> refuse_journal error
      | Ok journal ->
        let parent_invocation = Agent_core.Tool_contract.Invocation.create
            ~tool_use_id:source.parent_tool_use_id ~turn:source.source_turn
            ~schedule:(Agent_core.Tool_contract.Invocation.schedule invocation)
            ~completion:Agent_core.Tool_contract.Continue_after_success in
        let turn_context = original_source_context ~source:(Journal.source journal)
            ~observation:(Journal.source_observation journal) (Some turn_context) in
        let original_nested = Keeper_composition_nested_run.create ~calls:(Draft.nested_calls draft)
            ~composition_run_id:source.composition_run_id ~parent_invocation
            ~delivery_parent_tool_use_id:(Keeper_composition_nested_run.async_result_parent source.composition_run_id)
            ~tool_name ~record_activation:None () in
        Option.iter (fun bound -> Keeper_composition_nested_run.restore_admissions original_nested
          ~find_activation:(fun ~invocation ~tool_name ~scope ~reference ->
            Keeper_skill_activation_recorder.find_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference)) nested_activation;
        (match Keeper_composition_nested_run.check_original_admissions original_nested
          ~child_history:(fun ~node_ids -> Ok (Journal.continuation_child_admission continuation ~node_ids)) with
         | Keeper_composition_nested_run.Original_authority_held rejection ->
             hold rejection.detail;
             Tool_result.make_err ~tool_name ~start_time
             ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect
             ~data:rejection.data rejection.detail
         | Keeper_composition_nested_run.Original_admitted ->
           let refusal = match owner_metadata_refusal,refusal,skill_reference with
             | Some metadata_refusal,_,_ when Draft.nested_calls draft = [] ->
               Some (Original_owner_metadata_refused metadata_refusal)
             | (None | Some _),Some refusal,(None | Some _) -> Some refusal
             | None,None,Some reference when not producer_admitted && Draft.nested_calls draft = [] ->
               if Keeper_capability_surface.changed_skill_proven capability_surface reference then
                 Some (Original_producer_changed reference)
               else if Keeper_capability_surface.exact_skill_absence_proven capability_surface reference then
                 Some (Original_producer_absent reference)
               else None
             | (None | Some _),None,(None | Some _) -> None in
           if (Option.is_some owner_metadata_refusal || not producer_admitted) && Option.is_none refusal then
             refuse_journal Journal.Source_conflict
           else match (match refusal with None -> Ok () | Some _ -> validate_original_producer_activation ~config source) with
           | Error detail ->
               hold detail;
               Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
               ~effect_disposition:Tool_result.Proven_pre_effect detail
           | Ok () ->
           let on_producer_accepted,observe_settlement = match refusal with
             | None -> None,None
             | Some _ -> on_refusal_accepted,observe_refusal_settlement in
           async_submission_result ?on_recovery_held ?skill_reference ~journal ~continuation ?refusal
          ?on_producer_accepted ?observe_settlement
          ~nested_calls:(Draft.nested_calls draft) ?nested_activation
          ~draft_reference:source.draft_reference ~run_reference:source.run_reference
          ~composition_run_id:source.composition_run_id ~plan:(Draft.plan draft)
          ~tool_name ~tool_kind:Keeper_tool_descriptor.Async_composition_tool
          ~parent_invocation ~config ~meta
          ~capability_authority:(Keeper_tool_runtime.Frozen_surface capability_surface)
          ~publication_recovery ~ctx_snapshot ~turn_context ?clock ()
        |> bind_prepared_result ~composition_run_id:source.composition_run_id
            ~run_reference:source.run_reference ~draft_reference:source.draft_reference
        )
    )
;;

let resume_continuation ?on_recovery_held ?owner_metadata_refusal ~capability_surface ~continuation ~config ~meta
    ~publication_recovery ~ctx_snapshot ~turn_context ~invocation ?clock () =
  resume_continuation_with ?on_recovery_held ?owner_metadata_refusal ~capability_surface ~continuation ~config ~meta
    ~publication_recovery ~ctx_snapshot ~turn_context ~invocation ?clock ()
;;
