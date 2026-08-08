(** Immutable admission and scheduling plan for one tool-use turn. *)

type 'a execution_batch =
  | Concurrent_batch of 'a list
  | Serial_batch of 'a

type 'a t =
  | Admitted of 'a execution_batch list
  | Rejected_terminal_mix of 'a list

let execution_batches tool_uses =
  let flush_concurrent acc = function
    | [] -> acc
    | concurrent_tools -> Concurrent_batch (List.rev concurrent_tools) :: acc
  in
  let rec build acc current_concurrent = function
    | [] -> List.rev (flush_concurrent acc current_concurrent)
    | tool_use :: rest ->
      (match snd tool_use with
       | Tool_contract.Concurrent -> build acc (tool_use :: current_concurrent) rest
       | Tool_contract.Serial ->
         let acc = flush_concurrent acc current_concurrent in
         build (Serial_batch tool_use :: acc) [] rest)
  in
  build [] [] tool_uses
;;

let create ~execution_mode ~completion scheduled =
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
    Admitted
      (execution_batches (List.map (fun value -> value, execution_mode value) scheduled)
       |> List.map (function
         | Concurrent_batch values -> Concurrent_batch (List.map fst values)
         | Serial_batch value -> Serial_batch (fst value)))
  | 1, [ tool_use ] -> Admitted [ Serial_batch tool_use ]
  | _ -> Rejected_terminal_mix scheduled
;;
