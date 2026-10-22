module Store = Keeper_checkpoint_store
let ( let* ) = Result.bind

type authority = { trace_id : Keeper_id.Trace_id.t; observed : Keeper_checkpoint_ref.t option; session_dir : string }
type canonical = Present of Store.exact_checkpoint_snapshot | Absent | Superseded | Undecodable
(* Frozen bytes, rather than a checkpoint with a mutable Context, carry intent. *)
type action = Payload of { source : Keeper_checkpoint_ref.t option; bytes : string;
                          remove_undecodable : bool; cleared_message_count : int }
            | No_payload of canonical
type plan = { authority : authority; session_dir : string; action : action }
type history =
  | Emptied of { cleared_message_count : int; checkpoint_found : bool }
  | Removed of { checkpoint_path : string; undecodable : Store.checkpoint_load_error }
type receipt = { authority : authority; checkpoint : Keeper_checkpoint_ref.t option; history : history }
type error =
  | Invalid_clear of string
  | Canonical_unreadable of Store.checkpoint_ref_load_error
  | Retained_unavailable of Store.checkpoint_cas_error
  | Installation_unconfirmed of Store.checkpoint_installation
  | Removal_unconfirmed of Store.undecodable_removal_error

let authorize ~session_root ~trace_id ~observed =
  {trace_id;observed;session_dir=Filename.concat session_root (Keeper_id.Trace_id.to_string trace_id)}
let trace_id (authority : authority) = authority.trace_id
let predecessor (authority : authority) = authority.observed
let belongs_to receipt authority = receipt.authority == authority
let checkpoint receipt = receipt.checkpoint
let history receipt = receipt.history
let error_to_string = function
  | Invalid_clear detail -> detail
  | Canonical_unreadable error -> Store.checkpoint_ref_load_error_to_string error
  | Retained_unavailable _ -> "the exact owned input payload is unavailable; preserve and reconcile its evidence"
  | Installation_unconfirmed _ -> "history checkpoint installation or retention was not durably confirmed; preserve its evidence"
  | Removal_unconfirmed error -> Store.undecodable_removal_error_to_string error

let canonical ~session_dir ~session_id =
  match Store.load_agent_core_exact_snapshot ~session_dir ~session_id with
  | Ok snapshot -> Ok (Present snapshot)
  | Error Store.Ref_not_found -> Ok Absent
  | Error (Store.Ref_read_failed (Store.Superseded_version _)) -> Ok Superseded
  | Error (Store.Ref_read_failed (Store.Parse_error _ | Store.Store_error _)) -> Ok Undecodable
  | Error (Store.Ref_read_failed (Store.Not_found | Store.Newer_version _
      | Store.Io_error _ | Store.Read_failed _ | Store.Agent_core_error _)
      | Store.Ref_identity_invalid _ | Store.Ref_session_mismatch _
      | Store.Ref_lock_failed _ as error) -> Error (Canonical_unreadable error)

let decode bytes = Agent_core.Checkpoint.of_string bytes
  |> Result.map_error (fun error -> Invalid_clear (Agent_core.Error.to_string error))
let snapshot_checkpoint snapshot = decode (Store.exact_snapshot_canonical_bytes snapshot)
let nonwaiting checkpoint = match checkpoint.Agent_core.Checkpoint.pending_input with
  | None -> Ok ()
  | Some _ -> Error (Invalid_clear "history clear cannot discard a pending input request; resolve it first")
let kept_messages ~preserve_system messages =
  if not preserve_system then [] else List.filter (fun (message : Agent_core.Types.message) ->
    match message.role with System -> true | User | Assistant | Tool -> false) messages

let rec prefix expected actual = match expected,actual with
  | [],_ -> true
  | x::xs,y::ys -> x=y && prefix xs ys
  | _::_,[] -> false
let json checkpoint = Agent_core.Checkpoint.to_json_result checkpoint
  |> Result.map_error (fun error -> Invalid_clear (Agent_core.Error.to_string error))
let boundary context = Keeper_repetition_judged.read_opt context
  |> Result.map_error (fun error -> Invalid_clear (Keeper_repetition_judged.error_to_string error))
(* A same-turn canonical may predate input consumption, or follow a partial
   clear. Ordinals alone establish neither relationship. Accept an exact
   nonhistory body or the existing, precisely validated repetition reset. *)
let same_turn_body ~input ~current =
  let* input_boundary = boundary input.Agent_core.Checkpoint.context in
  let* current_boundary = boundary current.Agent_core.Checkpoint.context in
  let context = Agent_core.Context.copy current.context in
  let* () = match input_boundary,current_boundary with
    | Some previous,Some {Keeper_repetition_judged.history_generation=Rewritten _;history_pairs=0;ledger_frontier}
        when Keeper_tool_call_index.equal_frontiers previous.ledger_frontier ledger_frontier ->
      Keeper_repetition_judged.record context previous; Ok ()
    | Some _,Some {Keeper_repetition_judged.history_generation=(Initial | Rewritten _);_}
    | (Some _ | None),None | None,Some _ -> Ok () in
  let* expected = json {input with messages=[]} in
  let* actual = json {current with messages=[];created_at=input.created_at;context} in
  if Yojson.Safe.equal expected actual then Ok () else
    Error (Invalid_clear "same-turn canonical and owned input disagree outside history; reconcile their exact state before clearing")
let baseline ~input ~current =
  if input.Agent_core.Checkpoint.turn_count > current.Agent_core.Checkpoint.turn_count then Ok input
  else
    let* () = if input.turn_count=current.turn_count then same_turn_body ~input ~current else Ok () in
    if prefix input.messages current.messages
       || current.messages=kept_messages ~preserve_system:true input.messages
       || current.messages=[]
    then Ok current
    else Error (Invalid_clear "canonical history has no proven relationship to its owned input; reconcile before clearing")

let prepare ~(authority:authority) ~session_dir ~preserve_system =
  let* () = if session_dir=authority.session_dir then Ok () else
    Error (Invalid_clear "history clear path differs from the original Owner workspace") in
  let session_id = Keeper_id.Trace_id.to_string authority.trace_id in
  let* canonical = canonical ~session_dir ~session_id in
  let* retained = match authority.observed with
    | None -> Ok None
    | Some reference ->
      if not (Keeper_id.Trace_id.equal reference.trace_id authority.trace_id)
      then Error (Invalid_clear "history clear predecessor belongs to another trace") else
      let* snapshot = Store.load_retained_exact_snapshot ~session_dir ~reference
        |> Result.map_error (fun error -> Retained_unavailable error) in
      let* checkpoint = snapshot_checkpoint snapshot in
      let* () = nonwaiting checkpoint in
      Ok (Some checkpoint) in
  let* source,base,remove_undecodable = match canonical,retained with
    | Present snapshot,(Some _ | None) ->
      let* current = snapshot_checkpoint snapshot in
      let* () = nonwaiting current in
      let* base = match retained with
        | Some input -> baseline ~input ~current
        | None -> Ok current in
      Ok (Some (Store.exact_snapshot_reference snapshot),Some base,false)
    | (Absent | Undecodable),Some input -> Ok (None,Some input,canonical=Undecodable)
    | Superseded,Some _ -> Error (Invalid_clear
        "an owned input cannot be reconciled with a superseded canonical format by history clear")
    | (Absent | Superseded | Undecodable),None -> Ok (None,None,false) in
  match base with
  | None -> Ok {authority;session_dir;action=No_payload canonical}
  | Some original ->
    let messages = kept_messages ~preserve_system original.Agent_core.Checkpoint.messages in
    let* context = Keeper_repetition_judged.reset_history original.context
      |> Result.map_error (fun error -> Invalid_clear (Keeper_repetition_judged.error_to_string error)) in
    let candidate = {original with messages;context} in
    let* snapshot = Store.exact_snapshot_of_value ~expected_session_id:authority.trace_id candidate
      |> Result.map_error (fun error -> Canonical_unreadable error) in
    Ok {authority;session_dir;action=Payload {source;
      bytes=Store.exact_snapshot_canonical_bytes snapshot;remove_undecodable;
      cleared_message_count=List.length original.messages - List.length messages}}

let remove_undecodable ~session_dir ~session_id =
  match Store.remove_undecodable_canonical ~session_dir ~session_id with
  | Ok (Store.Removed {undecodable}) -> Ok (Some undecodable)
  | Ok Store.Canonical_absent -> Ok None
  | Ok Store.Canonical_loadable -> Error (Invalid_clear
      "canonical history changed into a loadable checkpoint before removal")
  | Error error -> Error (Removal_unconfirmed error)
let confirmed outcome = Store.require_confirmed_installation outcome
  |> Result.map_error (fun outcome -> Installation_unconfirmed outcome)

let execute plan =
  let {authority;session_dir;action} = plan in
  let session_id = Keeper_id.Trace_id.to_string authority.trace_id in
  match action with
  | Payload {source;bytes;remove_undecodable=remove;cleared_message_count} ->
    let* snapshot = Store.exact_snapshot_of_canonical_bytes ~expected_session_id:authority.trace_id bytes
      |> Result.map_error (fun error -> Canonical_unreadable error) in
    let* _retained = confirmed (Store.retain_exact_snapshot ~session_dir snapshot) in
    let* () = if remove then Result.map ignore (remove_undecodable ~session_dir ~session_id) else Ok () in
    let* candidate = decode bytes in
    let* checkpoint = confirmed (match source with
      | Some expected_source_ref -> Store.save_agent_core_if_source ~session_dir ~expected_source_ref candidate
      | None -> Store.save_agent_core_if_absent ~session_dir candidate) in
    if not (Keeper_checkpoint_ref.equal checkpoint (Store.exact_snapshot_reference snapshot))
    then Error (Invalid_clear "installed history differs from its retained clear payload") else
    Ok {authority;checkpoint=Some checkpoint;history=Emptied {cleared_message_count;checkpoint_found=true}}
  | No_payload Undecodable ->
    let* removed = remove_undecodable ~session_dir ~session_id in
    let history = match removed with
      | Some undecodable -> Removed {checkpoint_path=Store.agent_core_checkpoint_path ~session_dir ~session_id;undecodable}
      | None -> Emptied {cleared_message_count=0;checkpoint_found=false} in
    Ok {authority;checkpoint=None;history}
  | No_payload (Absent | Superseded) ->
    let* current = canonical ~session_dir ~session_id in
    (match current with
     | Absent | Superseded -> Ok {authority;checkpoint=None;
         history=Emptied {cleared_message_count=0;checkpoint_found=false}}
     | Present _ | Undecodable -> Error (Invalid_clear "canonical history appeared before the no-payload clear"))
  | No_payload (Present _) -> Error (Invalid_clear "a decoded history requires a retained clear payload")

let append_marker receipt ~keepers_dir ~keeper_name =
  match receipt.checkpoint with
  | None -> Ok ()
  | Some reference ->
    let record : Keeper_turn_boundaries.record =
      { recorded_at=Time_compat.now ();
        event=Keeper_turn_boundaries.History_restarted {trace_id=Keeper_id.Trace_id.to_string reference.trace_id} } in
    match Keeper_turn_boundaries.append ~keepers_dir ~keeper_id:keeper_name record with
    | Ok () -> Ok ()
    | Error error -> Error (Keeper_turn_boundaries.append_error_to_string error)
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Error (Printexc.to_string exn)
