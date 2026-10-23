(** Execute the exact retained review; authority and commitment stay on host. *)
module AR = Task.Anti_rationalization
module O = Verifier_review_owner
module V = Verifier_review_original
module Authority = Verification_authority_tools
let ( let* ) = Result.bind

type error =
  | Original_not_found
  | Original_corrupt of string
  | Grants_mismatch of string

let map_load_error = function
  | O.Not_found -> Original_not_found
  | O.Load_store_unavailable detail | O.Corrupt_original detail -> Original_corrupt detail

let run_attempt ?on_verdict ?on_tool_result ?sw ~store ~verification_id ~attempt
    ~installation_id ~package_id ~authority ~provider_rest () =
  let* original = O.load_for_destination ~store ~verification_id ~attempt
    ~installation_id ~package_id |> Result.map_error map_load_error in
  let subject = Authority.task_review_subject authority in
  let req = V.review_request original in
  let lookup = Authority.task_review_lookup authority in
  let* () =
    if String.equal subject.id verification_id
      && String.equal subject.task_id req.AR.task_id
      && String.equal subject.worker req.agent_name
      && String.equal (V.lookup_binding original) (Authority.task_review_binding authority)
      && V.lookup_root original = Authority.task_review_root authority
      && V.lookup_schemas original =
        List.map (fun (schema : Types_core.tool_schema) -> schema.name) lookup.AR.schemas
    then Ok () else Error (Grants_mismatch "retained subject or lookup authority differs") in
  let* () = Authority.validate_task_review authority
    |> Result.map_error (fun detail -> Grants_mismatch detail) in
  let* () =
    if String.equal (V.output_contract original) (V.canonical_output_contract ()) then Ok ()
    else Error (Original_corrupt "retained output contract differs from the review protocol") in
  Ok (AR.review_rendered ?on_verdict ?on_tool_result ?sw
    ~prompt:(V.system_prompt_text original)
    ~lookup ~provider_rest
    ~base_path:(Authority.task_review_base_path authority) req)
