module Memory = Keeper_memory_os_types
module Current = Keeper_memory_os_current
module Support = Keeper_memory_os_support_core
module Disposition = Keeper_memory_os_disposition_core
module Id_set = Set_util.StringSet
module Payloads = Set_util.StringMap
open Result.Syntax

type error =
  | Duplicate_current_identity of string
  | Keeper_mismatch of
      { expected : Keeper_identity.Keeper_id.t
      ; observed : Keeper_identity.Keeper_id.t
      }
  | Batch_turn_mismatch of { expected : Ids.Turn_ref.t; observed : Ids.Turn_ref.t }
  | Current_input_mismatch
  | Duplicate_step_run of string

let error_to_string = function
  | Duplicate_current_identity identity -> "duplicate staged Memory identity: " ^ identity
  | Keeper_mismatch {expected; observed} ->
    Printf.sprintf "Memory step Keeper mismatch: expected %s, observed %s"
      (Keeper_identity.Keeper_id.to_string expected)
      (Keeper_identity.Keeper_id.to_string observed)
  | Batch_turn_mismatch {expected; observed} ->
    Printf.sprintf "Memory step batch mismatch: expected %s, observed %s"
      (Ids.Turn_ref.to_string expected) (Ids.Turn_ref.to_string observed)
  | Current_input_mismatch -> "Memory step did not judge the staged current facts"
  | Duplicate_step_run run_id -> "Memory inference run already staged: " ^ run_id

type stage =
  { step : Keeper_librarian_runtime.memory_step
  ; current : Keeper_librarian.current_selection
  ; invalidated : Current.support_invalidation list
  ; claims_not_applied : Memory.fact list
  }

type t =
  { keeper_id : Keeper_identity.Keeper_id.t
  ; turn_ref : Ids.Turn_ref.t
  ; snapshot : Current.t option
  ; selection : Keeper_librarian.current_selection option
  ; stages_rev : stage list
  ; run_ids : Id_set.t
  }

let payloads facts =
  let rec loop acc = function
    | [] -> Ok acc
    | fact :: rest ->
      let identity = Memory.memory_id fact in
      if Payloads.mem identity acc then Error (Duplicate_current_identity identity)
      else loop (Payloads.add identity (Support.fact_payload fact) acc) rest
  in
  loop Payloads.empty facts

let selection_payloads = function
  | None -> Ok None
  | Some (selection : Keeper_librarian.current_selection) ->
    payloads selection.facts |> Result.map Option.some

let make ~keeper_id ~turn_ref ~snapshot ~selection =
  let* _ = selection_payloads selection in
  Ok {keeper_id; turn_ref; snapshot; selection; stages_rev=[]; run_ids=Id_set.empty}

let create ~keeper_id ~turn_ref ~snapshot =
  make ~keeper_id ~turn_ref ~snapshot
    ~selection:(Option.map
      (fun (snapshot : Current.t) ->
         ({facts=snapshot.facts} : Keeper_librarian.current_selection))
      snapshot)

let create_over ~keeper_id ~turn_ref ~current =
  make ~keeper_id ~turn_ref ~snapshot:None ~selection:current

let initial_snapshot plan = plan.snapshot
let current plan = plan.selection
let stages plan = List.rev plan.stages_rev

let append plan (step : Keeper_librarian_runtime.memory_step) =
  let input = step.source_input in
  let* () =
    if Keeper_identity.Keeper_id.equal plan.keeper_id input.keeper_id then Ok ()
    else Error (Keeper_mismatch {expected=plan.keeper_id; observed=input.keeper_id})
  in
  let* () =
    if Ids.Turn_ref.equal plan.turn_ref input.turn_ref then Ok ()
    else Error (Batch_turn_mismatch {expected=plan.turn_ref; observed=input.turn_ref})
  in
  let* () =
    if Id_set.mem step.run_id plan.run_ids then Error (Duplicate_step_run step.run_id)
    else Ok ()
  in
  let* expected = selection_payloads plan.selection in
  let* observed = selection_payloads input.current in
  let same_current =
    match expected, observed with
    | None, None -> true
    | Some expected, Some observed -> Payloads.equal String.equal expected observed
    | None, Some _ | Some _, None -> false
  in
  if not same_current then Error Current_input_mismatch
  else
    let current_facts = match plan.selection with None -> [] | Some selection -> selection.facts in
    let disposition = Disposition.plan ~current:current_facts ~dropped:step.dropped
      ~absorbed:step.absorbed ~revisions:step.revisions ~new_claims:step.new_claims in
    let invalidated =
      List.map
        (fun (entry : Keeper_memory_os_current_types.support_invalidation) ->
           {Current.fact=entry.fact; missing_premise_ids=entry.missing_premise_ids})
        disposition.invalidated
    in
    let current : Keeper_librarian.current_selection = {facts=disposition.facts} in
    let stage = {step; current; invalidated; claims_not_applied=disposition.claims_refused} in
    Ok {plan with selection=Some current; stages_rev=stage :: plan.stages_rev;
      run_ids=Id_set.add step.run_id plan.run_ids}
