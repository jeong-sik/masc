module Capture = Keeper_librarian_floor_step_request
module Owner = Keeper_librarian_durable_request

module Journal = Keeper_librarian_original_gate.Make (struct
  type owner = Owner.owner
  type t = Capture.t
  let gate_scope owner =
    "keeper-librarian-floor-step-gate/" ^ Agent_core_sha256.(digest_string (Capture.scope owner) |> to_hex)
  let gate_kind = "librarian-floor-step-gate"
  let scope = Capture.scope
  let keeper_id = Owner.keeper_id
  let base_path = Owner.base_path
  let keepers_dir = Owner.keepers_dir
  let observe_owner = Owner.observe_owner
  let owner_to_json = Owner.owner_to_json
  let owner_matches_json = Owner.owner_matches_json
  let request_id = Capture.request_id
  let to_json = Capture.to_json
  let decode_final = Capture.decode_final
  let confirm_final = Capture.confirm_final
  let gate_inputs step proposal =
    Capture.validate_proposal step proposal
    |> Result.map (fun (step_proposal : Keeper_librarian_runtime.durable_step_proposal) ->
         step_proposal.proposal.absorption)
end)
include Journal
