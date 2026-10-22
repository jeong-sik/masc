module Store = Keeper_checkpoint_store
let ( let* ) = Result.bind

type t =
  | Unobserved of Keeper_id.Trace_id.t
  | Pending of {checkpoint:Keeper_checkpoint_ref.t;pending:Agent_core.Agent_input_request.pending}
  | Consumed of Keeper_checkpoint_ref.t

type error =
  | Owner_unavailable of Keeper_owner_registry.command_error
  | Trace_changed of {expected:Keeper_id.Trace_id.t;actual:Keeper_id.Trace_id.t}
  | Prior_input_unavailable
  | Retained_unavailable of Store.checkpoint_cas_error

let read ~base_path ~keeper_name ~expected_trace =
  let* owner = Keeper_owner_registry.current_input_checkpoint ~base_path ~keeper_name
    |> Result.map_error (fun error -> Owner_unavailable error) in
  let* () = if Keeper_id.Trace_id.equal owner.trace_id expected_trace then Ok ()
    else Error (Trace_changed {expected=expected_trace;actual=owner.trace_id}) in
  match owner.observation with
  | Keeper_chat_operation_store.Prior_input_unavailable -> Error Prior_input_unavailable
  | Input_unobserved -> Ok (Unobserved owner.trace_id)
  | Input_observed reference ->
    let session_dir=Filename.concat owner.session_root (Keeper_id.Trace_id.to_string owner.trace_id) in
    let* snapshot=Store.load_retained_exact_snapshot ~session_dir ~reference
      |> Result.map_error (fun error -> Retained_unavailable error) in
    let checkpoint=Store.exact_snapshot_reference snapshot in
    match (Store.exact_snapshot_checkpoint snapshot).pending_input with
    | None -> Ok (Consumed checkpoint)
    | Some pending -> Ok (Pending {checkpoint;pending})

let error_json = function
  | Owner_unavailable error -> `Assoc ["kind",`String "owner_unavailable";
      "detail",`String (Keeper_owner_registry.command_error_to_string error)]
  | Trace_changed {expected;actual} -> `Assoc ["kind",`String "trace_changed";
      "expected",`String (Keeper_id.Trace_id.to_string expected);
      "actual",`String (Keeper_id.Trace_id.to_string actual)]
  | Prior_input_unavailable -> `Assoc ["kind",`String "prior_input_unavailable"]
  | Retained_unavailable error ->
    let kind,detail = match error with
      | Store.Source_unavailable error -> "source_unavailable",Store.checkpoint_ref_load_error_to_string error
      | Source_changed _ -> "source_changed","retained input bytes no longer match the owned reference"
      | Candidate_identity_invalid error -> "identity_invalid",Store.checkpoint_identity_error_to_string error
      | Candidate_session_mismatch _ -> "session_mismatch","retained input session differs from the owned trace"
      | Candidate_turn_regressed _ -> "turn_regressed","retained input turn differs from the owned reference"
      | Commit_not_installed _ -> "commit_not_installed","retained input could not be read without installation failure" in
    `Assoc ["kind",`String "retained_unavailable";"cause",`String kind;"detail",`String detail]
let reference_json (reference:Keeper_checkpoint_ref.t) = `Assoc
  ["trace_id",`String (Keeper_id.Trace_id.to_string reference.trace_id);
   "turn_count",`Int reference.turn_count;"sha256",`String reference.sha256]
let to_json result =
  let status,trace_id,reference,pending,error = match result with
    | Ok (Unobserved trace_id) -> "unobserved",`String (Keeper_id.Trace_id.to_string trace_id),`Null,`Null,`Null
    | Ok (Consumed reference) -> "owned_none",`String (Keeper_id.Trace_id.to_string reference.trace_id),
      reference_json reference,`Null,`Null
    | Ok (Pending {checkpoint;pending}) -> "owned_pending",`String (Keeper_id.Trace_id.to_string checkpoint.trace_id),
      reference_json checkpoint,Agent_core.Agent_input_request.pending_to_json pending,`Null
    | Error error -> "unavailable",`Null,`Null,`Null,error_json error in
  `Assoc ["schema",`String "masc.keeper.input-wait.observation.v2";
    "source",`String "retained_input_owner";"status",`String status;"trace_id",trace_id;
    "checkpoint_ref",reference;"pending_input",pending;"error",error]
