module Capture = Keeper_librarian_admission_capture
open Result.Syntax

let inputs capture proposal : (Keeper_librarian_original_gate.inputs, string) result =
  let* accepted = Capture.validate_proposal capture proposal in
  match accepted with
  | Keeper_librarian_runtime.Deferred -> Error "Deferred admission cannot start absorption"
  | Accepted accepted ->
    Ok (Keeper_librarian_runtime.absorption_input (Capture.input capture) accepted)

module Journal = Keeper_librarian_original_gate.Make (struct
  type owner = Capture.owner
  type t = Capture.t
  let gate_scope_prefix = "keeper-librarian-admission-gate/"
  let gate_scope owner =
    gate_scope_prefix ^ Capture.scope_hash (Capture.scope_identity owner)
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
  let request = Capture.request
  let decode_final = Capture.decode_final
  let confirm_final = Capture.confirm_final
  let gate_inputs = inputs
end)
include Journal
