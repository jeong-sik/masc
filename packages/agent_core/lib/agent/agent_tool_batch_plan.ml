(** Immutable admission and scheduling plan for one tool-use turn. *)

module Index_map = Map.Make (Int)

type 'a scoped_node =
  { local_index : int
  ; value : 'a
  ; predecessors : int list
  ; batch_offset : int
  }

type 'a scoped_group =
  { nodes : 'a scoped_node list
  ; batch_sizes : int Index_map.t
  }

type 'a execution_batch =
  | Concurrent_batch of 'a list
  | Serial_batch of 'a
  | Scoped_batch of 'a scoped_group

type 'a t =
  | Admitted of 'a execution_batch list
  | Rejected_terminal_mix of 'a list

let scopes_conflict left right =
  List.exists
    (fun occupied -> List.exists (Tool_contract.Resource_scope.conflicts occupied) right)
    left
;;

(* Keep every earlier resource conflict as an explicit edge. Static wave
   coordinates remain useful invocation metadata, but are not a barrier for
   disjoint nodes: a successor waits for its own predecessors, including a
   predecessor that is itself blocked, rather than an unrelated slow peer. *)
let scoped_group calls =
  let nodes =
    calls
    |> List.mapi (fun local_index (value, scopes) -> local_index, value, scopes)
    |> List.fold_left
      (fun earlier (local_index, value, scopes) ->
         let predecessors =
           List.rev earlier
           |> List.filter_map (fun (node, prior_scopes) ->
             if scopes_conflict prior_scopes scopes then Some node else None)
         in
         let batch_offset = List.fold_left
             (fun offset node -> max offset (node.batch_offset + 1)) 0 predecessors in
         let node =
           { local_index; value; batch_offset
           ; predecessors = List.map (fun node -> node.local_index) predecessors
           } in
         (node, scopes) :: earlier)
      []
    |> List.rev_map fst
  in
  let batch_sizes = List.fold_left (fun counts node ->
      Index_map.update node.batch_offset
        (function None -> Some 1 | Some count -> Some (count + 1)) counts)
      Index_map.empty nodes in
  { nodes; batch_sizes }
;;

let execution_batches ~execution_mode ~resource_scopes tool_uses =
  let rec take_scoped acc = function
    | value :: rest ->
      (match resource_scopes value with
       | Some scopes -> take_scoped ((value, scopes) :: acc) rest
       | None -> List.rev acc, value :: rest)
    | [] -> List.rev acc, []
  in
  let rec take_concurrent acc = function
    | value :: rest ->
      (match resource_scopes value, execution_mode value with
       | None, Tool_contract.Concurrent -> take_concurrent (value :: acc) rest
       | Some _, (Tool_contract.Concurrent | Tool_contract.Serial)
       | None, Tool_contract.Serial -> List.rev acc, value :: rest)
    | [] -> List.rev acc, []
  in
  let rec build acc = function
    | [] -> List.rev acc
    | value :: rest ->
      (match resource_scopes value, execution_mode value with
       | Some _, (Tool_contract.Concurrent | Tool_contract.Serial) ->
         let scoped, rest = take_scoped [] (value :: rest) in
         build (Scoped_batch (scoped_group scoped) :: acc) rest
       | None, Tool_contract.Concurrent ->
         let concurrent, rest = take_concurrent [] (value :: rest) in
         build (Concurrent_batch concurrent :: acc) rest
       | None, Tool_contract.Serial -> build (Serial_batch value :: acc) rest)
  in
  build [] tool_uses
;;

let create ?(resource_scopes = fun _ -> None) ~execution_mode ~completion scheduled =
  let terminal_count =
    List.fold_left
      (fun count tool_use ->
         match completion tool_use with
         | Tool_contract.Continue_after_success -> count
         | Tool_contract.Terminal_after_success _ -> count + 1)
      0
      scheduled
  in
  match terminal_count, scheduled with
  | 0, _ ->
    Admitted (execution_batches ~execution_mode ~resource_scopes scheduled)
  | 1, [ tool_use ] -> Admitted [ Serial_batch tool_use ]
  | _ -> Rejected_terminal_mix scheduled
;;
