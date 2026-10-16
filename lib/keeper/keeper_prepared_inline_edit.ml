module Plan = Keeper_tool_plan
module FS = Keeper_tool_filesystem_runtime

type leaf =
  { node : Plan.node
  ; input : Yojson.Safe.t
  ; edit : FS.prepared_edit
  }

type t =
  { plan : Plan.t
  ; source : Keeper_tool_call_log_context.turn_context
  ; leaves : leaf list
  }

let eligible plan =
  Plan.nodes plan <> [] && List.for_all (fun (node : Plan.node) ->
    match Plan.descriptor plan node.id with
    | None -> false
    | Some descriptor ->
      descriptor.Keeper_tool_descriptor.runtime_handler = Keeper_tool_descriptor.Tool_edit_file
      && descriptor.execution = Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Serial)
    (Plan.nodes plan)
;;

let source_matches (meta : Keeper_meta_contract.keeper_meta)
    (source : Keeper_tool_call_log_context.turn_context) =
  source.agent_name = Some meta.name
  && source.trace_id = Some (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  && source.task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
  && Option.is_some source.keeper_turn_id
;;

let prepare ~sw ~config ~meta ~source plan =
  match source with
  | None -> None
  | Some source when not (source_matches meta source && eligible plan) -> None
  | Some source ->
    match Plan.prepare_inputs plan with
    | Error _ -> None
    | Ok inputs ->
      let acquired = ref [] in
      let release () = List.iter FS.release_prepared_edit !acquired in
      let rec collect leaves = function
        | [] -> Some {plan; source; leaves = List.rev leaves}
        | (node : Plan.node) :: rest ->
          match Plan.descriptor plan node.id,
                List.find_opt (fun (id, _) -> Plan.Node_id.equal id node.id) inputs with
          | Some descriptor, Some (_, Plan.Checked_before_run input) ->
            (match Keeper_tool_descriptor_resolution.prepare_model_input_for_descriptor
                ~tool_name:node.tool_name descriptor ~input with
             | Error _ -> None
             | Ok args ->
               match FS.prepare_edit ~sw ~config ~meta ~args with
               | Error _ | Ok None -> None
               | Ok (Some edit) ->
                 acquired := edit :: !acquired;
                 collect ({node; input; edit} :: leaves) rest)
          | None, _ | _, None | _, Some (_, Plan.Checked_when_node_runs) -> None
      in
      (match collect [] (Plan.nodes plan) with
       | Some _ as prepared -> prepared
       | None -> release (); None
       | exception error ->
         let backtrace = Printexc.get_raw_backtrace () in
         release ();
         Printexc.raise_with_backtrace error backtrace)
;;

let plan t = t.plan
let source t = t.source
let scopes t = List.concat_map (fun leaf -> FS.prepared_edit_scopes leaf.edit) t.leaves

let for_node ~plan ~node ~input t =
  if not (plan == t.plan) then Error "prepared Inline Edit belongs to a different plan"
  else match List.find_opt (fun leaf -> leaf.node == node) t.leaves with
    | Some leaf when Yojson.Safe.equal input leaf.input -> Ok leaf.edit
    | Some _ -> Error "prepared Inline Edit model input changed"
    | None -> Error "prepared Inline Edit node is outside its original plan"
;;
