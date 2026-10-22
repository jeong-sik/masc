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
type authority = { session_dir:string; operation_id:Keeper_chat_operation.Operation_id.t; waiting:Semantic.input_wait }
type receipt = { authority:authority; checkpoint:Keeper_checkpoint_ref.t }
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
let authorize ~session_root ~operation_id ~waiting =
  {session_dir=Filename.concat session_root (Keeper_id.Trace_id.to_string waiting.Semantic.checkpoint.trace_id);
   operation_id;waiting}
let waiting (authority:authority) = authority.waiting
let belongs_to (receipt:receipt) authority = receipt.authority == authority
let installed_checkpoint (receipt:receipt) = receipt.checkpoint
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
let install ~net ~(authority:authority) ~response =
  let waiting=authority.waiting in
  let* retained = Store.load_retained_exact_snapshot ~session_dir:authority.session_dir ~reference:waiting.checkpoint
    |> Result.map_error (fun error -> Retained_unavailable error) in
  let original=Store.exact_snapshot_checkpoint retained in
  let* () = if same_pending waiting.pending original.pending_input then Ok () else
    Error (Invalid_response "retained input no longer contains its complete original request") in
  let* () = validate_scope authority original in
  let* source = Store.load_agent_core_exact_snapshot ~session_dir:authority.session_dir
      ~session_id:(Keeper_id.Trace_id.to_string waiting.checkpoint.trace_id)
    |> Result.map_error (fun error -> Canonical_unavailable error) in
  let current=Store.exact_snapshot_checkpoint source in
  let* () = if current.turn_count >= original.turn_count
      && same_pending waiting.pending current.pending_input && prefix original.messages current.messages
    then Ok () else Error (Invalid_response "canonical input disagrees with its original retained wait; reconcile before responding") in
  let* () = validate_scope authority current in
  let* retained_body=nonhistory original in
  let* canonical_body=nonhistory current in
  let* () = if Yojson.Safe.equal retained_body canonical_body then Ok () else
    Error (Invalid_response "canonical and retained input differ outside proven history; reconcile before responding") in
  let* prepared = prepare ~net ~expected_source_ref:(Store.exact_snapshot_reference source)
      ~source ~pending:waiting.pending ~response |> Result.map_error (fun error -> Response_refused error) in
  let candidate=checkpoint prepared in
  let context=Agent_core.Context.copy candidate.context in
  (match Agent_core.Context.get_scoped context Session "message_count" with
   | None -> ()
   | Some _ -> Agent_core.Context.set_scoped context Session "message_count" (`Int (List.length candidate.messages)));
  let candidate={candidate with Agent_core.Checkpoint.context} in
  let* frozen = Store.exact_snapshot_of_value ~expected_session_id:waiting.checkpoint.trace_id candidate
    |> Result.map_error (fun error -> Canonical_unavailable error) in
  let* candidate=Agent_core.Checkpoint.of_string (Store.exact_snapshot_canonical_bytes frozen)
    |> Result.map_error (fun error -> Invalid_response (Agent_core.Error.to_string error)) in
  let confirmed outcome = Store.require_confirmed_installation outcome
    |> Result.map_error (fun outcome -> Installation_unconfirmed outcome) in
  let* retained_reference=confirmed (Store.retain_exact_snapshot ~session_dir:authority.session_dir frozen) in
  let* installed=confirmed (Store.save_agent_core_if_source ~session_dir:authority.session_dir
      ~expected_source_ref:(Store.exact_snapshot_reference source) candidate) in
  if Keeper_checkpoint_ref.equal retained_reference installed then Ok {authority;checkpoint=installed}
  else Error (Installation_mismatch {retained=retained_reference;canonical=installed})
