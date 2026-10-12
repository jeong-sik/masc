module Snapshot = Keeper_repetition_snapshot
module Projection = Agent_core.Agent.Execution_projection
let ( let* ) = Result.bind

type error =
  | Scope_mismatch
  | Seed_observations_changed
  | Checkpoint_observation_not_settled
  | Invalid_settled_result
  | Unsupported_result_provenance
  | Repetition_error of Snapshot.error

let error_to_string = function
  | Scope_mismatch -> "native repetition evidence belongs to another execution scope"
  | Seed_observations_changed -> "native repetition checkpoint no longer contains its seed observations"
  | Checkpoint_observation_not_settled -> "native repetition checkpoint contains an observation absent from its canonical execution"
  | Invalid_settled_result -> "native repetition result has no exact settled invocation identity"
  | Unsupported_result_provenance -> "native repetition result lacks handler execution provenance"
  | Repetition_error error -> Snapshot.error_to_string error

let repetition result = Result.map_error (fun error -> Repetition_error error) result

let observation ?base_path (settled : Projection.settled_tool_invocation) =
  match settled.result with
  | Agent_core.Types.ToolResult {tool_use_id; content; outcome; _} ->
    let* () = if String.equal tool_use_id
        (Agent_core.Tool_contract.Invocation.tool_use_id settled.invocation)
      then Ok () else Error Invalid_settled_result in
    let* executed =
      if not settled.attempt_admitted then Ok false
      else match outcome with
        | Agent_core.Types.Tool_succeeded
        | Tool_failed {failure_kind=(Recoverable_tool_error | Non_retryable_tool_error); _} -> Ok true
        | Tool_failed {failure_kind=Validation_error; _} -> Ok false
        | Tool_failed {failure_kind=(Reported_tool_error | Unattributed_tool_error); _} ->
          Error Unsupported_result_provenance in
    if not executed then Ok None
    else
      let fingerprints = Keeper_tool_progress_identity.digest_tool_io ?base_path
          ~tool_name:settled.tool_name ~input:settled.input ~output_text:content () in
      let* observation = Snapshot.observation ~tool_name:settled.tool_name
          ~input_fingerprint:(Option.map
            (fun (io : Keeper_tool_progress_identity.io_fingerprints) -> io.input_fingerprint)
            fingerprints)
          ~output_fingerprint:(Option.map
            (fun (io : Keeper_tool_progress_identity.io_fingerprints) -> io.output_fingerprint)
            fingerprints) |> repetition in
      Ok (Some observation)
  | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
  | ToolUse _ | Image _ | Document _ | Audio _ -> Error Invalid_settled_result

let remove_once expected observations =
  let rec remove earlier = function
    | [] -> Error Checkpoint_observation_not_settled
    | actual :: rest when actual = expected -> Ok (List.rev_append earlier rest)
    | actual :: rest -> remove (actual :: earlier) rest
  in
  remove [] observations

let reconcile ?base_path ~scope ~seed ~checkpoint ~settled () =
  let owns state = match Snapshot.active state with
    | Some actual -> Keeper_execution_scope_id.equal actual scope
    | None -> false in
  let* () = if owns seed && owns checkpoint then Ok () else Error Scope_mismatch in
  let* seed_observations = Snapshot.observations seed ~scope |> repetition in
  let* checkpoint_observations = Snapshot.observations checkpoint ~scope |> repetition in
  let current_count = List.length checkpoint_observations - List.length seed_observations in
  let* recorded =
    if current_count < 0 then Error Seed_observations_changed
    else if List.drop current_count checkpoint_observations <> seed_observations
    then Error Seed_observations_changed
    else Ok (List.take current_count checkpoint_observations) in
  let* canonical_reversed = List.fold_left (fun acc settled ->
    let* acc = acc in
    let* observed = observation ?base_path settled in
    Ok (match observed with None -> acc | Some observed -> observed :: acc))
      (Ok []) settled in
  let* missing = List.fold_left (fun remaining recorded ->
    let* remaining = remaining in
    remove_once recorded remaining) (Ok (List.rev canonical_reversed)) recorded in
  List.fold_left (fun state observation ->
    let* state = state in
    Snapshot.record state ~scope observation |> repetition) (Ok checkpoint) missing
