module Capture = Keeper_librarian_admission_capture
module Queue = Keeper_memory_admission_queue
open Result.Syntax

let inputs capture proposal : (Keeper_librarian_original_gate.inputs, string) result =
  let* accepted = Capture.validate_proposal capture proposal in
  match accepted with
  | Keeper_librarian_runtime.Deferred -> Error "Deferred admission cannot start absorption"
  | Accepted accepted ->
    let input = Capture.input capture in
    let selected = accepted.selection in
    let observations = Keeper_librarian.observations_for_absorption input @
      (Queue.candidates (Capture.batch capture)
       |> List.filter (fun (row : Queue.candidate) -> List.mem row.request_id accepted.admission_support)
       |> List.map (fun (row : Queue.candidate) ->
         `Assoc ["observation_kind", `String "pending_explicit_memory_candidate";
           "request_id", `String row.request_id; "sequence", `Int row.sequence;
           "proposal", Keeper_memory_os_types.fact_to_json row.fact])) in
    Ok ({observations;facts=(match input.current with None -> [] | Some current -> current.facts);
      new_claims=selected.new_claims;
      superseding=List.map (fun (revision : Keeper_librarian.revision) -> revision.superseded_by) selected.revisions;
      absorbed=selected.absorbed} : Keeper_librarian_original_gate.inputs)

module Journal = Keeper_librarian_original_gate.Make (struct
  type owner = Capture.owner
  type t = Capture.t
  let gate_scope owner =
    "keeper-librarian-admission-gate/" ^ Capture.scope_hash (Capture.scope_identity owner)
  let gate_kind = "librarian-admission-gate"
  let scope = Capture.scope
  let keeper_id = Capture.keeper_id
  let base_path = Capture.base_path
  let keepers_dir = Capture.keepers_dir
  let observe_owner = Capture.observe_owner
  let owner_to_json = Capture.owner_to_json
  let owner_matches_json = Capture.owner_matches_json
  let request_id = Capture.request_id
  let to_json = Capture.to_json
  let decode_final = Capture.decode_final
  let confirm_final = Capture.confirm_final
  let gate_inputs = inputs
end)
include Journal
