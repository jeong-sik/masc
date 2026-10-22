module Checkpoint = Keeper_checkpoint_store
let ( let* ) = Result.bind
type t = {source_bytes:string; cut_bytes:string; source_ref:Keeper_checkpoint_ref.t;
          cut_ref:Keeper_checkpoint_ref.t}
type binding = {source:Keeper_checkpoint_ref.t; cut:Keeper_checkpoint_ref.t;
                seed:Keeper_checkpoint_ref.t}
let decode bytes = Agent_core.Checkpoint.of_string bytes |> Result.map_error Agent_core.Error.to_string
let source_checkpoint t = decode t.source_bytes
let cut_checkpoint t = decode t.cut_bytes
let rec prefix expected actual = match expected,actual with
  | [],_ -> true
  | x::xs,y::ys -> x=y && prefix xs ys
  | _::_,[] -> false
let contains_tool_result (message:Agent_core.Types.message) = List.exists (function
  | Agent_core.Types.ToolResult _ -> true
  | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
  | ToolUse _ | Image _ | Document _ | Audio _ -> false) message.content
let json checkpoint = Agent_core.Checkpoint.to_json_result checkpoint
  |> Result.map_error Agent_core.Error.to_string
let prepare ~source ~candidate =
  let source_bytes=Checkpoint.exact_snapshot_canonical_bytes source in
  let* original=decode source_bytes in
  let* () = match original.pending_input,candidate.Agent_core.Checkpoint.pending_input with
    | None,None -> Ok ()
    | (Some _ | None),(Some _ | None) -> Error "response cut cannot discard or consume pending input" in
  let* messages=match List.rev original.messages with
    | ({Agent_core.Types.role=Assistant;_} as last)::earlier when not (contains_tool_result last) ->
      Ok (List.rev earlier)
    | {Agent_core.Types.role=(Assistant | User | System | Tool);_}::_ | [] ->
      Error "response cut must remove exactly the final incomplete Assistant message" in
  let* expected=json {original with messages} in
  let* actual=json {candidate with created_at=original.created_at} in
  let* ()=if Yojson.Safe.equal expected actual then Ok ()
    else Error "response cut differs from its exact retired source" in
  let source_ref=Checkpoint.exact_snapshot_reference source in
  let* cut=Checkpoint.exact_snapshot_of_value ~expected_session_id:source_ref.trace_id candidate
    |> Result.map_error Checkpoint.checkpoint_ref_load_error_to_string in
  Ok {source_bytes;cut_bytes=Checkpoint.exact_snapshot_canonical_bytes cut;source_ref;
      cut_ref=Checkpoint.exact_snapshot_reference cut}
let validate_candidate t = function
  | None -> Error "response cut requires its exact candidate checkpoint"
  | Some candidate ->
    let* actual=json candidate in
    if Yojson.Safe.equal actual (Yojson.Safe.from_string t.cut_bytes) then Ok ()
    else Error "response cut candidate changed after authorization"
let bind_seed t ~seed =
  let* cut=cut_checkpoint t in
  let* actual=decode (Checkpoint.exact_snapshot_canonical_bytes seed) in
  let seed=Checkpoint.exact_snapshot_reference seed in
  let* ()=match actual.pending_input with
    | None when Keeper_id.Trace_id.equal seed.trace_id t.cut_ref.trace_id
        && prefix cut.messages actual.messages -> Ok ()
    | Some _ | None -> Error "next native seed does not preserve the exact input history cut" in
  Ok {source=t.source_ref;cut=t.cut_ref;seed}
let checkpoint binding = binding.cut
let validate_native binding ~observed ~(call:Keeper_native_call.t) =
  match observed with
  | Keeper_native_call.Terminal_unacknowledged (previous,{Agent_core.Agent.recovery=Retire;_})
      when Keeper_checkpoint_ref.equal previous.checkpoint binding.source
        && Keeper_checkpoint_ref.equal call.seed_checkpoint binding.seed
        && Keeper_checkpoint_ref.equal call.checkpoint binding.seed -> Ok ()
  | Terminal_unacknowledged (_, {Agent_core.Agent.recovery=(Retire | Operator_repair_required Effect_outcome_unknown);_})
  | Active _ | No_native_call ->
    Error "input history cut no longer owns its retired source and next native seed"
