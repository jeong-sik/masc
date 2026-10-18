module Plan = Keeper_tool_plan
module FS = Keeper_tool_filesystem_runtime

type operation = Read of FS.prepared_read | Edit of FS.prepared_edit | Write of FS.prepared_write

type leaf =
  { node : Plan.node
  ; input : Yojson.Safe.t
  ; operation : operation
  }

type t =
  { plan : Plan.t
  ; source : Keeper_tool_call_log_context.turn_context
  ; leaves : leaf list
  }

let is_file descriptor =
  descriptor.Keeper_tool_descriptor.runtime_handler = Keeper_tool_descriptor.Tool_read_file
  || descriptor.runtime_handler = Keeper_tool_descriptor.Tool_edit_file
  || descriptor.runtime_handler = Keeper_tool_descriptor.Tool_write_file
;;

let supported_file descriptor =
  ((descriptor.Keeper_tool_descriptor.runtime_handler = Keeper_tool_descriptor.Tool_edit_file
    || descriptor.runtime_handler = Keeper_tool_descriptor.Tool_write_file)
   && descriptor.execution = Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Serial)
  || (descriptor.runtime_handler = Keeper_tool_descriptor.Tool_read_file
      && descriptor.execution = Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Concurrent)
;;

let eligible plan =
  let nodes = Plan.nodes plan in
  let is_mutation (node : Plan.node) =
    Option.fold ~none:false ~some:(fun descriptor ->
      descriptor.Keeper_tool_descriptor.runtime_handler = Keeper_tool_descriptor.Tool_edit_file
      || descriptor.runtime_handler = Keeper_tool_descriptor.Tool_write_file)
      (Plan.descriptor plan node.id)
  in
  List.exists is_mutation nodes && List.for_all (fun (node : Plan.node) ->
    match Plan.descriptor plan node.id with
    | None -> false
    | Some descriptor -> supported_file descriptor) nodes
;;

let release = function
  | Read read -> FS.release_prepared_read read
  | Edit edit -> FS.release_prepared_edit edit
  | Write write -> FS.release_prepared_write write

let operation_scopes = function
  | Read read -> FS.prepared_read_scopes read
  | Edit edit -> FS.prepared_edit_scopes edit
  | Write write -> FS.prepared_write_scopes write

let source_matches (meta : Keeper_meta_contract.keeper_meta)
    (source : Keeper_tool_call_log_context.turn_context) =
  source.agent_name = Some meta.name
  && source.trace_id = Some (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  && source.task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
  && Option.is_some source.keeper_turn_id
;;

let prepare_operation ~sw ~config ~meta ~tool_name descriptor ~input =
  if not (is_file descriptor) then None
  else
  match Keeper_tool_descriptor_resolution.prepare_model_input_for_descriptor
      ~tool_name descriptor ~input with
  | Error _ -> None
  | Ok args ->
    if descriptor.runtime_handler = Keeper_tool_descriptor.Tool_read_file then
      (match FS.prepare_read ~sw ~config ~meta ~args with
       | Ok (Some read) -> Some (Read read)
       | Ok None | Error _ -> None)
    else if descriptor.runtime_handler = Keeper_tool_descriptor.Tool_edit_file then
      (match FS.prepare_edit ~sw ~config ~meta ~args with
       | Ok (Some edit) -> Some (Edit edit)
       | Ok None | Error _ -> None)
    else
      (match FS.prepare_write ~sw ~config ~meta ~args with
       | Ok (Some write) -> Some (Write write)
       | Ok None | Error _ -> None)
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
      let release_acquired () = List.iter release !acquired in
      let rec collect leaves = function
        | [] -> Some {plan; source; leaves = List.rev leaves}
        | (node : Plan.node) :: rest ->
          match Plan.descriptor plan node.id,
                List.find_opt (fun (id, _) -> Plan.Node_id.equal id node.id) inputs with
          | Some descriptor, Some (_, Plan.Checked_before_run input) ->
            (match prepare_operation ~sw ~config ~meta ~tool_name:node.tool_name descriptor ~input with
               | None -> None
               | Some operation ->
                 acquired := operation :: !acquired;
                 collect ({node; input; operation} :: leaves) rest)
          | None, _ | _, None | _, Some (_, Plan.Checked_when_node_runs) -> None
      in
      (match collect [] (Plan.nodes plan) with
       | Some _ as prepared -> prepared
       | None -> release_acquired (); None
       | exception error ->
         let backtrace = Printexc.get_raw_backtrace () in
         release_acquired ();
         Printexc.raise_with_backtrace error backtrace)
;;

let plan t = t.plan
let source t = t.source
let scopes t = List.concat_map (fun leaf -> operation_scopes leaf.operation) t.leaves

let resource_dependencies ~plan t =
  if not (plan == t.plan) then None
  else
    let leaves = Plan.dependency_layers plan |> List.concat_map (fun nodes ->
      List.map (fun node ->
        match List.find_opt (fun leaf -> leaf.node == node) t.leaves with
        | Some leaf -> leaf
        | None -> invalid_arg "prepared Inline file lost its original node") nodes) in
    let rec collect earlier = function
      | [] -> []
      | leaf :: rest ->
        let scopes = operation_scopes leaf.operation in
        let predecessors = List.filter_map (fun prior ->
          let prior_scopes = operation_scopes prior.operation in
          if List.exists (fun scope ->
            List.exists (Agent_core.Tool_contract.Resource_scope.conflicts scope) prior_scopes) scopes
          then Some prior.node.Plan.id else None) earlier in
        (leaf.node.id, predecessors) :: collect (leaf :: earlier) rest
    in
    Some (collect [] leaves)
;;

let for_node ~plan ~node ~input t =
  if not (plan == t.plan) then Error "prepared Inline file belongs to a different plan"
  else match List.find_opt (fun leaf -> leaf.node == node) t.leaves with
    | Some leaf when Yojson.Safe.equal input leaf.input -> Ok leaf.operation
    | Some _ -> Error "prepared Inline file model input changed"
    | None -> Error "prepared Inline file node is outside its original plan"
;;

module Ready = struct
  type ordering = No_order | Wait_for_settlement | Require_success

  type t =
    { plan : Plan.t
    ; sw : Eio.Switch.t
    ; config : Workspace.config
    ; meta : Keeper_meta_contract.keeper_meta
    ; preparation_orders : (Plan.Node_id.t * (Plan.Node_id.t * ordering) list) list
    }

  type binding =
    | Pure_arguments
    | Ordinary of Keeper_tool_descriptor.ordinary_execution_mode
    | Unprepared_file of Keeper_tool_descriptor.ordinary_execution_mode
    | Prepared_file of operation

  let preparation_orders plan =
    let before_prepare prior current = match prior.Keeper_tool_descriptor.execution,current.Keeper_tool_descriptor.execution with
      | Ordinary Serial, Ordinary Serial -> Require_success
      | Ordinary Concurrent, Ordinary Concurrent -> No_order
      | Ordinary (Serial | Concurrent), Ordinary (Serial | Concurrent) -> Wait_for_settlement
      | Terminal, _ | _, Terminal -> No_order in
    let rec collect earlier orders = function
      | [] -> List.rev orders
      | (node : Plan.node) :: rest ->
        match Plan.descriptor plan node.id with
        | None -> collect earlier orders rest
        | Some descriptor when not (is_file descriptor) -> collect ((node.id,descriptor) :: earlier) orders rest
        | Some descriptor ->
          let predecessors = List.filter_map (fun (id,prior) -> match before_prepare prior descriptor with
            | No_order -> None | (Wait_for_settlement | Require_success) as order -> Some (id,order)) earlier
            |> List.rev in
          let orders = match predecessors with [] -> orders | _ :: _ -> (node.id,predecessors) :: orders in
          collect earlier orders rest in
    collect [] [] (List.concat (Plan.dependency_layers plan))
  ;;

  let create ~sw ~config ~meta ~source plan =
    let nodes = Plan.nodes plan in
    let has_mutation = List.exists (fun (node : Plan.node) ->
      match Plan.descriptor plan node.id with
      | Some descriptor ->
        descriptor.Keeper_tool_descriptor.runtime_handler = Keeper_tool_descriptor.Tool_edit_file
        || descriptor.runtime_handler = Keeper_tool_descriptor.Tool_write_file
      | None -> false) nodes in
    let supported = List.for_all (fun (node : Plan.node) ->
      match Plan.contract plan node.id with
      | Some {target = Plan.Child_arguments _; _} -> true
      | Some {target = Plan.Descriptor_target descriptor; _} ->
        if is_file descriptor then supported_file descriptor
        else (match descriptor.execution with
          | Keeper_tool_descriptor.Ordinary (Serial | Concurrent) -> true
          | Keeper_tool_descriptor.Terminal -> false)
      | Some {target = (Plan.Child_submission _ | Plan.Child_result _); _} | None -> false) nodes in
    match source with
    | Some source when source_matches meta source && has_mutation && supported ->
      Some {plan; sw; config; meta; preparation_orders=preparation_orders plan}
    | Some _ | None -> None
  ;;

  let plan t = t.plan

  let preparation_predecessors t ~node =
    match List.find_opt (fun (id,_) -> Plan.Node_id.equal id node.Plan.id) t.preparation_orders with
    | Some (_,orders) -> orders | None -> []
  ;;

  let bind t ~node ~input =
    if not (List.exists (fun member -> member == node) (Plan.nodes t.plan)) then
      invalid_arg "ready Inline file node is outside its original plan";
    match Plan.contract t.plan node.Plan.id with
    | Some {target = Plan.Child_arguments _; _} -> Pure_arguments
    | Some {target = Plan.Descriptor_target descriptor; _} ->
      (match descriptor.execution with
       | Keeper_tool_descriptor.Terminal -> invalid_arg "ready file plan contains a terminal leaf"
       | Keeper_tool_descriptor.Ordinary mode ->
         if not (is_file descriptor) then Ordinary mode
         else match prepare_operation ~sw:t.sw ~config:t.config ~meta:t.meta
             ~tool_name:node.tool_name descriptor ~input with
           | Some operation -> Prepared_file operation
           | None -> Unprepared_file mode)
    | Some {target = (Plan.Child_submission _ | Plan.Child_result _); _} | None ->
      invalid_arg "ready Inline file lost its original producer"
  ;;

  let operation = function
    | Prepared_file operation -> Some operation
    | Pure_arguments | Ordinary _ | Unprepared_file _ -> None

  let exclusive = function
    | Unprepared_file _ | Ordinary Keeper_tool_descriptor.Serial -> true
    | Pure_arguments | Prepared_file _ | Ordinary Keeper_tool_descriptor.Concurrent -> false

  let originally_serial = function
    | Ordinary Keeper_tool_descriptor.Serial | Unprepared_file Keeper_tool_descriptor.Serial
    | Prepared_file (Edit _ | Write _) -> true
    | Pure_arguments | Ordinary Keeper_tool_descriptor.Concurrent
    | Unprepared_file Keeper_tool_descriptor.Concurrent | Prepared_file (Read _) -> false

  let ordering left right = match left, right with
    | Pure_arguments, _ | _, Pure_arguments -> No_order
    | Prepared_file left, Prepared_file right ->
      if List.exists (fun scope ->
        List.exists (Agent_core.Tool_contract.Resource_scope.conflicts scope)
          (operation_scopes right)) (operation_scopes left)
      then Require_success else No_order
    | Unprepared_file _, (Unprepared_file _ | Prepared_file _)
    | Prepared_file _, Unprepared_file _ -> Require_success
    | Ordinary Keeper_tool_descriptor.Concurrent, Ordinary Keeper_tool_descriptor.Concurrent
    | Ordinary Keeper_tool_descriptor.Concurrent, Prepared_file (Read _)
    | Prepared_file (Read _), Ordinary Keeper_tool_descriptor.Concurrent -> No_order
    | Ordinary _, (Ordinary _ | Unprepared_file _ | Prepared_file _)
    | (Unprepared_file _ | Prepared_file _), Ordinary _ ->
      (* Unknown footprint: preserve execution ordering, without claiming a
         shared file. Only an original Serial-to-Serial chain carries the
         legacy failure dependency; a concurrent lookup is just a barrier. *)
      if originally_serial left && originally_serial right then Require_success
      else Wait_for_settlement
  ;;
end
