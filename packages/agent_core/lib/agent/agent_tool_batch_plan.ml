(** Immutable admission and scheduling plan for one tool-use turn. *)

type 'a execution_batch =
  | Concurrent_batch of 'a list
  | Serial_batch of 'a

type 'a t =
  | Admitted of 'a execution_batch list
  | Rejected_terminal_mix of 'a list

let scopes_conflict left right =
  List.exists
    (fun occupied -> List.exists (Tool_contract.Resource_scope.conflicts occupied) right)
    left
;;

(* Every conflict with an earlier pending call is an ordering edge. Removing
   a whole ready wave preserves transitive edges too: C cannot overtake B
   just because B itself is waiting for A. *)
let scoped_batches calls =
  let rec waves acc = function
    | [] -> List.rev acc
    | pending ->
      let rec select earlier ready blocked = function
        | [] -> List.rev ready, List.rev blocked
        | ((value, scopes) as call) :: rest ->
          let is_blocked =
            List.exists (fun (_, prior) -> scopes_conflict prior scopes) earlier
          in
          select
            (call :: earlier)
            (if is_blocked then ready else value :: ready)
            (if is_blocked then call :: blocked else blocked)
            rest
      in
      let ready, blocked = select [] [] [] pending in
      waves (Concurrent_batch ready :: acc) blocked
  in
  waves [] calls
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
         build (List.rev_append (scoped_batches scoped) acc) rest
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
