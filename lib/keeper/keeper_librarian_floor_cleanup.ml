module Step = Keeper_librarian_floor_step_request
module Step_owner = Keeper_librarian_floor_step_owner
module Gate = Keeper_librarian_floor_step_gate
module Descent = Keeper_librarian_floor_descent
module Retained = Lane_addon_tool_request_owner
let ( let* ) = Result.bind
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f

let discover ~store ~owner = Step_owner.discover ~store ~owner |> Result.map_error Step_owner.error_to_string

(* A step belongs to the candidate whose original it names by ID and digest. *)
let owns candidate (header : Step.header) =
  let (mine : Step.link) = Descent.range candidate in
  let (named : Step.link) = header.range in
  String.equal mine.Step.request_id named.Step.request_id
  && String.equal mine.Step.request_digest named.Step.request_digest

(* The moves are the ones a history chain makes: one store call per record,
   under the caller's workspace lease. *)
let settle_record ~store ~date (record : Retained.retained) =
  Retained.settle ~store ~date (Retained.listed record) |> Result.map_error Retained.settle_error_to_string

let archived ~store ~scope ~date request_id =
  io (fun () -> Retained.settled ~store ~scope ~date ~request_id) |> Result.map_error Retained.error_to_string

let settle_gates ~store ~inventory ~date ~execution_id =
  List.fold_left (fun moved gate ->
    let* moved = moved in
    let* () = settle_record ~store ~date gate in
    Ok (moved + 1)) (Ok 0) (Gate.Inventory.execution_records inventory ~execution_id)

(* A chain resumes from the steps at positions 0 to k and refuses any other
   leftover, so the highest position settles first and a stop part way leaves
   such a prefix. The store lists steps by the digest of their IDs, which says
   nothing of position. *)
let highest_position_first steps =
  List.sort (fun (_, (a : Step.header)) (_, (b : Step.header)) -> Int.compare b.position a.position) steps

(* The step first, then the gate records of its judgment, as a history chain
   settles. A stop between the two leaves gate records of an archived step,
   which [settle_orphan_gates] reaches. *)
let settle_steps_with ~settle ~store ~owner steps =
  match steps with
  | [] -> Ok 0
  | _ :: _ ->
    let* inventory = io (fun () -> Gate.Inventory.read ~store ~owner) in
    List.fold_left (fun moved ((record : Retained.retained), _) ->
      let* moved = moved in
      let* date = Step.minted_on record.request_id in
      let* () = settle ~store ~date record in
      let* gates = settle_gates ~store ~inventory ~date ~execution_id:record.request_id in
      Ok (moved + 1 + gates)) (Ok 0) (highest_position_first steps)
let settle_steps = settle_steps_with ~settle:settle_record

(* Gate records of an archived step no longer change any validation. *)
let settle_orphan_gates ~store ~owner ~steps =
  let* inventory = io (fun () -> Gate.Inventory.read ~store ~owner) in
  let discovered execution_id = List.exists (fun ((record : Retained.retained), _) ->
    record.request_id = execution_id) steps in
  List.fold_left (fun moved execution_id ->
    let* moved = moved in
    if discovered execution_id then Ok moved else
    let* date = Step.minted_on execution_id in
    let* archived = archived ~store ~scope:(Step.scope owner) ~date execution_id in
    if not archived then Ok moved else
    let* gates = settle_gates ~store ~inventory ~date ~execution_id in
    Ok (moved + gates)) (Ok 0) (Gate.Inventory.executions inventory)

let cleanup ~store ~owner ~candidates =
  let* steps = discover ~store ~owner in
  let unowned = List.filter (fun (_, header) ->
    not (List.exists (fun candidate -> owns candidate header) candidates)) steps in
  let* settled = settle_steps ~store ~owner unowned in
  let* orphans = settle_orphan_gates ~store ~owner ~steps in
  Ok (settled + orphans)

let settle_chain ~store ~owner candidate =
  let* steps = discover ~store ~owner in
  settle_steps ~store ~owner (List.filter (fun (_, header) -> owns candidate header) steps)

let settle_step ~store ~owner candidate ~position =
  let* steps = discover ~store ~owner in
  match List.filter (fun (_, (header : Step.header)) ->
    owns candidate header && header.position = position) steps with
  | [] -> Error (Printf.sprintf "Floor chain has no retained step at position %d to settle" position)
  | stopped -> settle_steps ~store ~owner stopped

module For_testing = struct
  let settle_steps_with = settle_steps_with
end
