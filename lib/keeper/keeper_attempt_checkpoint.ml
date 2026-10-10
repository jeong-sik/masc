type t =
  { turn_result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; checkpoint_after : Agent_core.Checkpoint.t option
  }

let restore_turn_checkpoint projection checkpoint =
  Keeper_replay_prefix.restore_checkpoint projection checkpoint
  |> Result.map_error (fun error ->
       Agent_core.Error.Internal (Keeper_replay_prefix.restore_error_to_string error))

let project ?checkpoint_after ~projection provider_result =
  let turn_result =
    match provider_result with
    | Error _ as error -> error
    | Ok run_result ->
      (match run_result.Runtime_agent.checkpoint with
       | None -> Ok run_result
       | Some checkpoint ->
         restore_turn_checkpoint projection checkpoint
         |> Result.map (fun checkpoint ->
              { run_result with Runtime_agent.checkpoint = Some checkpoint }))
  in
  match checkpoint_after with
  | None -> { turn_result; checkpoint_after = None }
  | Some checkpoint ->
    (match restore_turn_checkpoint projection checkpoint with
     | Ok checkpoint -> { turn_result; checkpoint_after = Some checkpoint }
     | Error error -> { turn_result = Error error; checkpoint_after = None })

let canonical_sink ~projection sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
  let restored =
    Keeper_replay_prefix.restore_checkpoint projection snapshot.checkpoint
    |> Result.map_error Keeper_replay_prefix.restore_error_to_string
    |> Result.map (fun checkpoint -> { snapshot with checkpoint })
  in
  Result.bind restored sink
