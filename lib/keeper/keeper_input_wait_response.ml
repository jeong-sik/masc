type t =
  { source_ref : Keeper_checkpoint_ref.t
  ; checkpoint : Agent_core.Checkpoint.t
  }

type refusal =
  | Source_changed of Keeper_checkpoint_ref.t
  | Input_not_current of Agent_core.Agent_input_request.settlement_error
  | Input_checkpoint_failed of Agent_core.Error.t

let source_ref prepared = prepared.source_ref
let checkpoint prepared = prepared.checkpoint

let prepare ~net ~expected_source_ref ~source ~pending ~response =
  let source_ref = Keeper_checkpoint_store.exact_snapshot_reference source in
  if not (Keeper_checkpoint_ref.equal expected_source_ref source_ref)
  then Error (Source_changed source_ref)
  else
    let checkpoint = Keeper_checkpoint_store.exact_snapshot_checkpoint source in
    let agent = Agent_core.Agent.resume ~net ~checkpoint () in
    Fun.protect ~finally:(fun () -> Agent_core.Agent.close agent) (fun () ->
      match Agent_core.Agent.provide_input agent pending response with
      | Error (Agent_core.Agent.Input_not_current error) ->
        Error (Input_not_current error)
      | Error (Agent_core.Agent.Input_checkpoint_failed error) ->
        Error (Input_checkpoint_failed error)
      | Ok () ->
        let messages = (Agent_core.Agent.state agent).messages in
        let pending_input = Agent_core.Agent.pending_input agent in
        (* Rebuilding through Agent.checkpoint would drop source tool schemas,
           MCP/session/working-context metadata and replace its timestamp. *)
        Ok {source_ref; checkpoint = {checkpoint with messages; pending_input}})
