module Store = Keeper_checkpoint_store
module Core = Agent_core
let ( let* ) = Result.bind
type t = {source:Keeper_checkpoint_ref.t;candidate:Keeper_checkpoint_ref.t}
let original source =
  Core.Checkpoint.of_string (Store.exact_snapshot_canonical_bytes source)
  |> Result.map_error Core.Error.to_string
let rec prefix expected actual = match expected,actual with
  | [],_ -> true
  | x::xs,y::ys -> x=y && prefix xs ys
  | _::_,[] -> false
let freeze source (candidate:Core.Checkpoint.t) =
  (* This private copy is serialized on a checkpoint CPU worker and can also be
     revalidated inside the Owner's storage systhread. Its table is detached
     from the live Agent; a synchronous mutex keeps both paths independent of
     the caller's Eio cancellation context. *)
  let candidate={candidate with context=Core.Context.copy candidate.context ~eio:false} in
  Store.exact_snapshot_of_value ~expected_session_id:(Store.exact_snapshot_reference source).trace_id candidate
  |> Result.map_error Store.checkpoint_ref_load_error_to_string
let invariant source frozen =
  let candidate=Store.exact_snapshot_checkpoint frozen in
  let* original=original source in
  let* ()=if original.session_id=candidate.session_id && original.turn_count=candidate.turn_count
    then Ok () else Error "host transformation changed the original trace or turn" in
  let* ()=if Option.equal (fun a b -> Yojson.Safe.equal
      (Core.Agent_input_request.pending_to_json a) (Core.Agent_input_request.pending_to_json b))
      original.pending_input candidate.pending_input then Ok ()
    else Error "host transformation changed complete pending input ownership" in
  let frame checkpoint=Keeper_repetition_context.load checkpoint.Core.Checkpoint.context
    |> Result.map_error Keeper_repetition_snapshot.error_to_string in
  let* before=frame original in
  let* after=frame candidate in
  let* ()=if Keeper_repetition_snapshot.equal before after then Ok ()
    else Error "host transformation changed repetition evidence" in
  Ok {source=Store.exact_snapshot_reference source;candidate=Store.exact_snapshot_reference frozen}
let preserve ~source ~candidate =
  let* frozen=freeze source candidate in
  let candidate=Store.exact_snapshot_checkpoint frozen in
  let* original=original source in
  let* ()=if prefix original.messages candidate.Core.Checkpoint.messages then Ok ()
    else Error "host preparation lost the branch's exact message prefix" in
  invariant source frozen
let protected_message (message:Core.Types.message) =
  let has_tool_effect=List.exists (function
    | Core.Types.ToolUse _ | ToolResult _ -> true
    | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
    | Image _ | Document _ | Audio _ -> false) message.content in
  has_tool_effect || match message.role with
  | Core.Types.User ->
    (match Core.Types.Extra_system_context_provenance.classify message.metadata with
     | Historical -> false
     | Absent | Present | Invalid | Duplicate -> true)
  | Assistant | System | Tool -> false
let rec subsequence expected actual = match expected,actual with
  | [],_ -> true
  | x::xs,y::ys -> if x=y then subsequence xs ys else subsequence expected ys
  | _::_,[] -> false
let replay ~source ~history_messages ~response_text ~suppress_visible_response ~stop_reason =
  let* original=original source in
  let* candidate,pruned=Keeper_checkpoint_replay_projection.checkpoint_for_replay_persistence
      ~history_messages ~session_id:original.session_id ~response_text
      ~suppress_visible_response ~stop_reason ~exclude_thought_from_replay:false original in
  let* ()=match original.pending_input with
    | Some _ when not (prefix original.messages candidate.messages) ->
      Error "waiting input cannot lose any of its original message prefix"
    | Some _ | None -> Ok () in
  let protected=List.filter protected_message original.messages in
  let* ()=if subsequence protected candidate.messages then Ok ()
    else Error "host replay projection lost original input or a tool invocation/result" in
  let* frozen=freeze source candidate in
  let* proof=invariant source frozen in
  Ok (proof,Store.exact_snapshot_checkpoint frozen,pruned)
let incomplete_response_cut ~source ~candidate =
  let* frozen=freeze source candidate in
  let* _=Keeper_input_history_cut.prepare ~source ~candidate:(Store.exact_snapshot_checkpoint frozen) in
  invariant source frozen
let validate proof ~source ~candidate =
  if Keeper_checkpoint_ref.equal proof.source (Store.exact_snapshot_reference source)
    && Keeper_checkpoint_ref.equal proof.candidate (Store.exact_snapshot_reference candidate)
  then Ok () else Error "host transformation no longer names its exact retained source and candidate"
