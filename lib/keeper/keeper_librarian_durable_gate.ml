module Capture = Keeper_librarian_durable_request

module Journal = Keeper_librarian_original_gate.Make (struct
  type owner = Capture.owner
  type t = Capture.t
  let gate_scope owner =
    "keeper-librarian-durable-gate/" ^ Agent_core_sha256.(digest_string (Capture.scope owner) |> to_hex)
  let gate_kind = "librarian-durable-gate"
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
  let gate_inputs capture proposal =
    Capture.validate_proposal capture proposal
    |> Result.map (fun (proposal : Keeper_librarian_runtime.durable_proposal) -> proposal.absorption)
end)
include Journal
