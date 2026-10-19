module Plan = Keeper_tool_plan
module FS = Keeper_tool_filesystem_runtime
module Node_map = Map.Make (Plan.Node_id)

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
  ; leaves_by_id : leaf Node_map.t
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
      let rec collect leaves nodes inputs = match nodes, inputs with
        | [], [] ->
          let leaves = List.rev leaves in
          let leaves_by_id = List.fold_left (fun index leaf ->
            Node_map.add leaf.node.Plan.id leaf index) Node_map.empty leaves in
          Some {plan; source; leaves; leaves_by_id}
        | (node : Plan.node) :: rest, (id, prepared) :: remaining
            when Plan.Node_id.equal id node.id ->
          (match Plan.descriptor plan node.id, prepared with
          | Some descriptor, Plan.Checked_before_run input ->
            (match prepare_operation ~sw ~config ~meta ~tool_name:node.tool_name descriptor ~input with
               | None -> None
               | Some operation ->
                 acquired := operation :: !acquired;
                 collect ({node; input; operation} :: leaves) rest remaining)
          | None, _ | _, Plan.Checked_when_node_runs -> None)
        | [], _ :: _ | _ :: _, [] | _ :: _, _ :: _ -> None
      in
      (match collect [] (Plan.nodes plan) inputs with
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

type resource_ordering =
  { dependency_layers : Plan.node list list
  ; predecessors : (Plan.Node_id.t * Plan.Node_id.t list) list
  }

let resource_ordering ~plan t =
  if not (plan == t.plan) then None
  else
    let dependency_layers = Plan.dependency_layers plan in
    let leaves = dependency_layers |> List.concat_map (fun nodes ->
      List.map (fun node ->
        match Node_map.find_opt node.Plan.id t.leaves_by_id with
        | Some leaf when leaf.node == node -> leaf
        | Some _ | None -> invalid_arg "prepared Inline file lost its original node") nodes) in
    let rec collect earlier = function
      | [] -> []
      | leaf :: rest ->
        let scopes = operation_scopes leaf.operation in
        let predecessors = List.filter_map (fun (prior_id, prior_scopes) ->
          if List.exists (fun scope ->
            List.exists (Agent_core.Tool_contract.Resource_scope.conflicts scope) prior_scopes) scopes
          then Some prior_id else None) earlier in
        (leaf.node.id, predecessors) :: collect ((leaf.node.id, scopes) :: earlier) rest
    in
    let predecessors = collect [] leaves in
    Some {dependency_layers; predecessors}
;;

let for_node ~plan ~node ~input t =
  if not (plan == t.plan) then Error "prepared Inline file belongs to a different plan"
  else match Node_map.find_opt node.Plan.id t.leaves_by_id with
    | Some leaf when leaf.node == node ->
      if Yojson.Safe.equal input leaf.input then Ok leaf.operation
      else Error "prepared Inline file model input changed"
    | Some _ | None -> Error "prepared Inline file node is outside its original plan"
;;

module Ready = struct
  type ordering = No_order | Wait_for_settlement | Require_success

  type t =
    { plan : Plan.t
    ; dependency_layers : Plan.node list list
    ; sw : Eio.Switch.t
    ; config : Workspace.config
    ; meta : Keeper_meta_contract.keeper_meta
    ; members : (Plan.node * Plan.contract option) Node_map.t
    ; preparation_orders : (Plan.Node_id.t * ordering) list Node_map.t
    }

  type binding =
    | Pure_arguments
    | Ordinary of Keeper_tool_descriptor.ordinary_execution_mode
    | Unprepared_file of Keeper_tool_descriptor.ordinary_execution_mode
    | Prepared_file of
        { operation : operation
        ; scopes : Agent_core.Tool_contract.Resource_scope.t list
        }

  let preparation_orders dependency_layers (members : (Plan.node * Plan.contract option) Node_map.t) =
    let before_prepare prior current = match prior.Keeper_tool_descriptor.execution,current.Keeper_tool_descriptor.execution with
      | Ordinary Serial, Ordinary Serial -> Require_success
      | Ordinary Concurrent, Ordinary Concurrent -> No_order
      | Ordinary (Serial | Concurrent), Ordinary (Serial | Concurrent) -> Wait_for_settlement
      | Terminal, _ | _, Terminal -> No_order in
    let rec collect earlier orders = function
      | [] -> List.rev orders
      | (node : Plan.node) :: rest ->
        match Node_map.find_opt node.id members with
        | None | Some (_, None)
        | Some (_, Some {target = (Plan.Child_arguments _ | Plan.Child_submission _ | Plan.Child_result _); _}) ->
          collect earlier orders rest
        | Some (_, Some {target = Plan.Descriptor_target descriptor; _}) ->
          if not (is_file descriptor) then collect ((node.id,descriptor) :: earlier) orders rest
          else
            let predecessors = List.filter_map (fun (id,prior) -> match before_prepare prior descriptor with
              | No_order -> None | (Wait_for_settlement | Require_success) as order -> Some (id,order)) earlier
              |> List.rev in
            let orders = match predecessors with [] -> orders | _ :: _ -> (node.id,predecessors) :: orders in
            collect earlier orders rest in
    collect [] [] (List.concat dependency_layers)
  ;;

  let create ~sw ~config ~meta ~source plan =
    match source with
    | Some source when source_matches meta source ->
      (* Retain each supported original contract once. Binding may use it only
         after checking that its node is the same physical member. *)
      let rec collect members has_mutation = function
        | [] -> if has_mutation then Some members else None
        | (node : Plan.node) :: rest ->
          let contract = Plan.contract plan node.id in
          let supported, mutation = match contract with
            | Some {target = Plan.Child_arguments _; _} -> true, false
            | Some {target = Plan.Descriptor_target descriptor; _} ->
              let supported = if is_file descriptor then supported_file descriptor
                else match descriptor.execution with
                  | Keeper_tool_descriptor.Ordinary (Serial | Concurrent) -> true
                  | Keeper_tool_descriptor.Terminal -> false in
              supported,
              (descriptor.runtime_handler = Keeper_tool_descriptor.Tool_edit_file
               || descriptor.runtime_handler = Keeper_tool_descriptor.Tool_write_file)
            | Some {target = (Plan.Child_submission _ | Plan.Child_result _); _} | None -> false, false in
          if not supported then None
          else collect (Node_map.add node.id (node,contract) members) (has_mutation || mutation) rest in
      (match collect Node_map.empty false (Plan.nodes plan) with
       | None -> None
       | Some members ->
         let dependency_layers = Plan.dependency_layers plan in
         let preparation_orders = preparation_orders dependency_layers members
           |> List.fold_left (fun index (id, orders) -> Node_map.add id orders index) Node_map.empty in
         Some {plan; dependency_layers; sw; config; meta; members; preparation_orders})
    | Some _ | None -> None
  ;;

  let plan t = t.plan
  let dependency_layers (t : t) = t.dependency_layers

  let preparation_predecessors t ~node =
    match Node_map.find_opt node.Plan.id t.preparation_orders with
    | Some orders -> orders | None -> []
  ;;

  let bind t ~node ~input =
    let contract = match Node_map.find_opt node.Plan.id t.members with
      | Some (member, contract) when member == node -> contract
      | Some _ | None -> invalid_arg "ready Inline file node is outside its original plan" in
    match contract with
    | Some {target = Plan.Child_arguments _; _} -> Pure_arguments
    | Some {target = Plan.Descriptor_target descriptor; _} ->
      (match descriptor.execution with
       | Keeper_tool_descriptor.Terminal -> invalid_arg "ready file plan contains a terminal leaf"
       | Keeper_tool_descriptor.Ordinary mode ->
         if not (is_file descriptor) then Ordinary mode
         else match prepare_operation ~sw:t.sw ~config:t.config ~meta:t.meta
             ~tool_name:node.tool_name descriptor ~input with
           | Some operation -> Prepared_file {operation; scopes = operation_scopes operation}
           | None -> Unprepared_file mode)
    | Some {target = (Plan.Child_submission _ | Plan.Child_result _); _} | None ->
      invalid_arg "ready Inline file lost its original producer"
  ;;

  let operation = function
    | Prepared_file {operation; scopes = _} -> Some operation
    | Pure_arguments | Ordinary _ | Unprepared_file _ -> None

  let exclusive = function
    | Unprepared_file _ | Ordinary Keeper_tool_descriptor.Serial -> true
    | Pure_arguments | Ordinary Keeper_tool_descriptor.Concurrent
    | Prepared_file {operation = (Read _ | Edit _ | Write _); scopes = _} -> false

  let originally_serial = function
    | Ordinary Keeper_tool_descriptor.Serial | Unprepared_file Keeper_tool_descriptor.Serial
    | Prepared_file {operation = (Edit _ | Write _); scopes = _} -> true
    | Pure_arguments | Ordinary Keeper_tool_descriptor.Concurrent
    | Unprepared_file Keeper_tool_descriptor.Concurrent
    | Prepared_file {operation = Read _; scopes = _} -> false

  let ordering left right =
    let open Keeper_tool_descriptor in
    match left, right with
    | Pure_arguments, _ | _, Pure_arguments -> No_order
    | Prepared_file {operation = (Read _ | Edit _ | Write _); scopes = left_scopes},
      Prepared_file {operation = (Read _ | Edit _ | Write _); scopes = right_scopes} ->
      if List.exists (fun scope ->
        List.exists (Agent_core.Tool_contract.Resource_scope.conflicts scope)
          right_scopes) left_scopes
      then Require_success else No_order
    | Unprepared_file (Serial | Concurrent),
      (Unprepared_file (Serial | Concurrent)
        | Prepared_file {operation = (Read _ | Edit _ | Write _); scopes = _})
    | Prepared_file {operation = (Read _ | Edit _ | Write _); scopes = _}, Unprepared_file (Serial | Concurrent) ->
      Require_success
    | Ordinary Concurrent, Ordinary Concurrent
    | Ordinary Concurrent, Prepared_file {operation = Read _; scopes = _}
    | Prepared_file {operation = Read _; scopes = _}, Ordinary Concurrent -> No_order
    | Ordinary (Serial | Concurrent),
      (Ordinary (Serial | Concurrent) | Unprepared_file (Serial | Concurrent)
        | Prepared_file {operation = (Read _ | Edit _ | Write _); scopes = _})
    | (Unprepared_file (Serial | Concurrent)
        | Prepared_file {operation = (Read _ | Edit _ | Write _); scopes = _}),
      Ordinary (Serial | Concurrent) ->
      (* Unknown footprint: preserve execution ordering, without claiming a
         shared file. Only an original Serial-to-Serial chain carries the
         legacy failure dependency; a concurrent lookup is just a barrier. *)
      if originally_serial left && originally_serial right then Require_success
      else Wait_for_settlement
  ;;
end
