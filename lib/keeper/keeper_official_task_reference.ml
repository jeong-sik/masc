type t =
  { operation_id : Keeper_chat_operation.Operation_id.t
  ; admitted_message : string
  ; original_turn : Keeper_semantic_execution.official_client_checkpoint
  }
let create ~operation_id ~message ~original_turn =
  {operation_id; admitted_message=message; original_turn}

let marker_key = "masc_official_historical_task"

let is_reference (message : Agent_core.Types.message) =
  List.mem_assoc marker_key message.metadata

let message ~current reference =
  let original = reference.original_turn in
  let scope = Keeper_execution_scope_id.direct_operation reference.operation_id in
  match current, Keeper_repetition_snapshot.active original.frame with
  | Some current, Some original_scope
    when current.Keeper_semantic_execution.session_id = original.session_id
      && current.runtime_id = original.runtime_id && current.client_kind = original.client_kind
      && Keeper_execution_scope_id.equal scope original_scope ->
    let payload = `Assoc
      ["schema", `String "masc.official-client-historical-task.v1";
       "operation_id", `String (Keeper_chat_operation.Operation_id.to_string reference.operation_id);
       "execution_scope", Keeper_execution_scope_id.to_json scope;
       "original_vendor_turn", `Assoc ["session_id", `String original.session_id; "turn_id", `String original.turn_id];
       "admitted_message", `String reference.admitted_message;
       "interpretation", `String "Historical task reference, not a new user request. Apply newer steering; do not replay completed tools or attachments."] in
    Ok {(Agent_core.Types.system_msg (Yojson.Safe.to_string payload)) with
      metadata=[marker_key, `String "v1"]}
  | Some _, Some _ | Some _, None | None, _ ->
    Error "historical task reference is not bound to this operation's original vendor session"

let require_preserved ~reference messages = match reference with
  | None -> Ok ()
  | Some reference when List.exists ((=) reference) messages -> Ok ()
  | Some _ -> Error "required historical task reference was removed by model-input projection"
