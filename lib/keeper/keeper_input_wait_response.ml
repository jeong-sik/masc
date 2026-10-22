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


module Store = Keeper_checkpoint_store
module Semantic = Keeper_semantic_execution
let ( let* ) = Result.bind
type authority = { session_dir:string; operation_id:Keeper_chat_operation.Operation_id.t;
  waiting:Semantic.input_wait; destination:Semantic.input_response_destination;
  recorded:Semantic.input_response_intent option }
type installation_target = Canonical_predecessor of Keeper_checkpoint_ref.t | Branch_retention
type plan = { authority:authority; intent:Semantic.input_response_intent;
  target:installation_target; candidate:Agent_core.Checkpoint.t }
type receipt = { authority:authority; intent:Semantic.input_response_intent; checkpoint:Keeper_checkpoint_ref.t }
type installation_error =
  | Invalid_response of string
  | Retained_unavailable of Store.checkpoint_cas_error
  | Canonical_unavailable of Store.checkpoint_ref_load_error
  | Response_refused of refusal
  | Installation_unconfirmed of Store.checkpoint_installation
  | Installation_mismatch of
      { retained : Keeper_checkpoint_ref.t
      ; canonical : Keeper_checkpoint_ref.t
      }
let authorize ~session_root ~operation_id ~(waiting:Semantic.input_wait) ~destination ~recorded =
  {session_dir=Filename.concat session_root (Keeper_id.Trace_id.to_string waiting.Semantic.checkpoint.trace_id);
   operation_id;waiting;destination;recorded}
let waiting (authority:authority) = authority.waiting
let belongs_to (receipt:receipt) authority = receipt.authority == authority
let installed_checkpoint (receipt:receipt) = receipt.checkpoint
let planned_intent (plan:plan) = plan.intent
let plan_belongs_to (plan:plan) authority = plan.authority == authority
let installed_intent (receipt:receipt) = receipt.intent
let installation_error_to_string = function
  | Invalid_response detail -> detail
  | Retained_unavailable _ -> "original response retained input is unavailable; reconcile its evidence"
  | Canonical_unavailable error -> Store.checkpoint_ref_load_error_to_string error
  | Response_refused (Source_changed _) -> "response source changed"
  | Response_refused (Input_not_current _) -> "response request is no longer current"
  | Response_refused (Input_checkpoint_failed error) -> Agent_core.Error.to_string error
  | Installation_unconfirmed _ -> "response file installation is unconfirmed; preserve evidence and reconcile before retry"
  | Installation_mismatch _ -> "response canonical installation differs from its retained bytes; preserve both references and reconcile"
let rec prefix expected actual = match expected,actual with
  | [],_ -> true | x::xs,y::ys when x=y -> prefix xs ys
  | _::_,([] | _::_) -> false
let same_pending expected = function
  | None -> false
  | Some actual -> Yojson.Safe.equal (Agent_core.Agent_input_request.pending_to_json expected)
      (Agent_core.Agent_input_request.pending_to_json actual)
let validate_scope authority (checkpoint:Agent_core.Checkpoint.t) =
  let* frame = Keeper_repetition_context.load checkpoint.context
    |> Result.map_error (fun error -> Invalid_response (Keeper_repetition_snapshot.error_to_string error)) in
  match Keeper_repetition_snapshot.active frame with
  | Some scope when Keeper_execution_scope_id.equal scope
      (Keeper_execution_scope_id.direct_operation authority.operation_id) -> Ok ()
  | Some _ | None -> Error (Invalid_response "input response checkpoint lost its original operation scope")
(* Only the independently validated derived count and capture timestamp may
   differ. A same pending ID/prefix does not prove other context, tool, MCP or
   working-context changes; preserve both sources and require reconciliation. *)
let nonhistory (checkpoint:Agent_core.Checkpoint.t) =
  let context=Agent_core.Context.copy checkpoint.context in
  let* () = match Agent_core.Context.get_scoped context Session "message_count" with
    | None -> Ok ()
    | Some value when Yojson.Safe.equal value (`Int (List.length checkpoint.messages)) -> Ok ()
    | Some _ -> Error (Invalid_response "response source has an invalid derived message count") in
  Agent_core.Context.delete_scoped context Session "message_count";
  Agent_core.Checkpoint.to_json_result {checkpoint with context;messages=[];created_at=0.}
    |> Result.map_error (fun error -> Invalid_response (Agent_core.Error.to_string error))
let confirmed outcome = Store.require_confirmed_installation outcome
  |> Result.map_error (fun outcome -> Installation_unconfirmed outcome)
let retained authority reference = Store.load_retained_exact_snapshot
  ~session_dir:authority.session_dir ~reference |> Result.map_error (fun error -> Retained_unavailable error)
let validate_source authority original (source:Agent_core.Checkpoint.t) =
  let* () = if source.turn_count >= original.Agent_core.Checkpoint.turn_count
      && same_pending authority.waiting.pending source.pending_input && prefix original.messages source.messages
    then Ok () else Error (Invalid_response "response source disagrees with its original retained wait") in
  let* () = validate_scope authority source in
  let* retained_body = nonhistory original in
  let* source_body = nonhistory source in
  if Yojson.Safe.equal retained_body source_body then Ok ()
  else Error (Invalid_response "response source and retained wait differ outside proven history")
let frozen_response ~net authority source response =
  let waiting=authority.waiting in
  let* prepared = prepare ~net ~expected_source_ref:(Store.exact_snapshot_reference source)
      ~source ~pending:waiting.pending ~response |> Result.map_error (fun error -> Response_refused error) in
  let candidate=checkpoint prepared in
  let context=Agent_core.Context.copy candidate.context in
  (match Agent_core.Context.get_scoped context Session "message_count" with
   | None -> ()
   | Some _ -> Agent_core.Context.set_scoped context Session "message_count" (`Int (List.length candidate.messages)));
  Store.exact_snapshot_of_value ~expected_session_id:waiting.checkpoint.trace_id
    {candidate with Agent_core.Checkpoint.context}
    |> Result.map_error (fun error -> Canonical_unavailable error)
let prepare_installation ~net ~(authority:authority) ~response =
  let* response = Semantic.canonical_input_response response
    |> Result.map_error (fun detail -> Invalid_response detail) in
  let waiting=authority.waiting in
  let* original_snapshot = retained authority waiting.checkpoint in
  let original=Store.exact_snapshot_checkpoint original_snapshot in
  let* () = if same_pending waiting.pending original.pending_input then Ok () else
    Error (Invalid_response "retained input no longer contains its complete original request") in
  let* () = validate_scope authority original in
  let* () = match authority.recorded with
    | None -> Ok ()
    | Some intent ->
      let* supplied = Semantic.input_response_intent ~waiting ~source:intent.source ~candidate:intent.candidate ~response ~destination:authority.destination
        |> Result.map_error (fun detail -> Invalid_response detail) in
      if Semantic.continues_input_response_intent ~previous:intent ~next:supplied then Ok ()
      else Error (Invalid_response "another response cannot replace the original recorded intent") in
  let* canonical = match authority.destination with
    | Semantic.Canonical_input -> Store.load_agent_core_exact_snapshot ~session_dir:authority.session_dir
        ~session_id:(Keeper_id.Trace_id.to_string waiting.checkpoint.trace_id)
      |> Result.map Option.some |> Result.map_error (fun error -> Canonical_unavailable error)
    | Operation_input -> Ok None in
  let* source = match authority.recorded,canonical with
    | None,Some canonical -> Ok canonical
    | None,None -> Ok original_snapshot
    | Some intent,(Some _ | None) ->
      if Keeper_checkpoint_ref.equal waiting.checkpoint intent.source then Ok original_snapshot
      else retained authority intent.source in
  let* () = validate_source authority original (Store.exact_snapshot_checkpoint source) in
  let response=match authority.recorded with None -> response | Some intent -> intent.response in
  let* frozen = frozen_response ~net authority source response in
  let* intent = Semantic.input_response_intent ~waiting ~source:(Store.exact_snapshot_reference source)
      ~candidate:(Store.exact_snapshot_reference frozen) ~response ~destination:authority.destination
    |> Result.map_error (fun detail -> Invalid_response detail) in
  let* () = match authority.recorded with
    | None -> Ok ()
    | Some recorded ->
      if not (Semantic.continues_input_response_intent ~previous:recorded ~next:intent) then
        Error (Invalid_response "recorded response no longer derives its exact consumed candidate")
      else let* _ = retained authority recorded.candidate in Ok () in
  let* target = match canonical with
    | None -> Ok Branch_retention
    | Some canonical ->
      let predecessor=Store.exact_snapshot_reference canonical in
      if Keeper_checkpoint_ref.equal predecessor intent.source
          || (Option.is_some authority.recorded && Keeper_checkpoint_ref.equal predecessor intent.candidate)
      then Ok (Canonical_predecessor predecessor)
      else Error (Invalid_response "canonical changed outside the recorded response; reconcile its lineage") in
  (* Source can differ from W. Keep its actual bytes before canonical mutation,
     so restart never has to infer S from C or from an original history prefix. *)
  let* _ = confirmed (Store.retain_exact_snapshot ~session_dir:authority.session_dir source) in
  let* retained_candidate = confirmed (Store.retain_exact_snapshot ~session_dir:authority.session_dir frozen) in
  let* candidate=Agent_core.Checkpoint.of_string (Store.exact_snapshot_canonical_bytes frozen)
    |> Result.map_error (fun error -> Invalid_response (Agent_core.Error.to_string error)) in
  if Keeper_checkpoint_ref.equal retained_candidate intent.candidate then Ok {authority;intent;target;candidate}
  else Error (Installation_mismatch {retained=retained_candidate;canonical=intent.candidate})
let install (plan:plan) =
  let* installed = match plan.target with
    | Canonical_predecessor predecessor ->
      confirmed (Store.save_agent_core_if_source ~session_dir:plan.authority.session_dir
        ~expected_source_ref:predecessor plan.candidate)
    | Branch_retention ->
      let* snapshot=Store.exact_snapshot_of_value ~expected_session_id:plan.authority.waiting.checkpoint.trace_id
          plan.candidate |> Result.map_error (fun error -> Canonical_unavailable error) in
      confirmed (Store.retain_exact_snapshot ~session_dir:plan.authority.session_dir snapshot) in
  if Keeper_checkpoint_ref.equal plan.intent.candidate installed then
    Ok {authority=plan.authority;intent=plan.intent;checkpoint=installed}
  else Error (Installation_mismatch {retained=plan.intent.candidate;canonical=installed})
