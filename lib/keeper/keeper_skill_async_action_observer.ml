open Result.Syntax
module Recorder = Keeper_skill_activation_recorder
module Delivery = Keeper_composition_result_delivery
module Fact = Keeper_skill_async_action
module Invocation = Agent_core.Tool_contract.Invocation

type handle = { trace_id : Keeper_id.Trace_id.t; delivery : Keeper_skill_async_delivery.t }
type scope = unit ref * unit ref
type pending = { invocation : Invocation.t; tool_name : string; runtime_id : string; handles : handle list; scope : scope }
type snapshot = { active : handle list; pending : pending list; scope : scope }
type t =
  { config : Workspace.config; context : Recorder.t
  ; mutable snapshot : snapshot }
type error =
  | Delivery_failed of Delivery.error
  | Ledger_failed of Keeper_skill_activation_ledger.store_error
  | Invalid_evidence of string

let error_to_string = function
  | Delivery_failed error -> Delivery.error_to_string error
  | Ledger_failed error -> Keeper_skill_activation_ledger.store_error_to_string error
  | Invalid_evidence detail -> detail
let empty_snapshot () = {active=[];pending=[];scope=ref (),ref ()}
let create ~config ~context = {config;context;snapshot=empty_snapshot ()}
let clear state = state.snapshot <- empty_snapshot ()
let begin_handoff state =
  let snapshot = state.snapshot in
  state.snapshot <- {snapshot with scope=fst snapshot.scope,ref (); active=[]}
let same_scope (left_attempt,left_handoff) (right_attempt,right_handoff) =
  left_attempt == right_attempt && left_handoff == right_handoff
let clear_if_current state scope = if same_scope state.snapshot.scope scope then clear state
let refuse state scope error = clear_if_current state scope; Error error
let record_delivery state (observation : Delivery.observation) =
  let scope = state.snapshot.scope in
  if not (Ids.Turn_ref.equal observation.physical_turn_ref (Recorder.physical_turn_ref state.context))
     || Recorder.current_runtime_id state.context <> Some observation.runtime_id
  then Error (Invalid_evidence "handoff differs from the selected physical attempt")
  else match Delivery.persist ~config:state.config observation with
    | Error error -> refuse state scope (Delivery_failed error)
    | Ok None -> Ok None
    | Ok (Some delivery) ->
      (match delivery.presentation with
       | Manifest_reference -> ()
       | Inline_result ->
         let handle = {trace_id=Recorder.bound_trace_id (Delivery.original_recorder observation.binding);delivery} in
         if same_scope state.snapshot.scope scope && Recorder.current_runtime_id state.context = Some delivery.runtime_id
         then begin
           (* Read the owner again after the runtime callback: it may have
              yielded or selected another handoff before returning. *)
           let snapshot = state.snapshot in
           if same_scope snapshot.scope scope
              && not (List.exists (fun known -> String.equal (Keeper_skill_async_delivery.identity known.delivery)
               (Keeper_skill_async_delivery.identity delivery)) snapshot.active)
           then state.snapshot <- {snapshot with active=snapshot.active @ [handle]}
         end);
      Ok (Some delivery)
let same_occurrence invocation tool_name (pending : pending) =
  Keeper_skill_async_delivery.equal_invocation invocation pending.invocation && String.equal tool_name pending.tool_name
let record state ~handles ~runtime_id ~tool_name ~occurrence =
  List.fold_left (fun result (handle : handle) ->
    let* count = result in
    let* fact = Fact.make ~delivery_sha256:(Keeper_skill_async_delivery.identity handle.delivery)
      ~physical_turn_ref:(Recorder.physical_turn_ref state.context) ~runtime_id ~tool_name
      ~occurrence ~observed_at:(Masc_domain.now_iso ()) |> Result.map_error (fun detail -> Invalid_evidence detail) in
    let* _ = Keeper_skill_activation_ledger.observe_async_action ~config:state.config ~trace_id:handle.trace_id fact
      |> Result.map_error (fun error -> Ledger_failed error) in
    Ok (count+1)) (Ok 0) handles
let take_pending state ~invocation ~tool_name =
  let snapshot = state.snapshot in
  match List.find_opt (same_occurrence invocation tool_name) snapshot.pending with
  | None -> None
  | Some _ as found ->
      state.snapshot <- {snapshot with pending=List.filter (fun pending ->
        not (same_occurrence invocation tool_name pending)) snapshot.pending};
      found
let sdk_hook state ~on_error event =
  (match event with
   | Agent_core.Hooks.PreToolUse {invocation;tool_name;_} ->
     ignore (take_pending state ~invocation ~tool_name);
     (match Recorder.current_runtime_id state.context with
      | None -> ()
      | Some runtime_id ->
        let snapshot = state.snapshot in
        let pending = {invocation;tool_name;runtime_id;handles=snapshot.active;scope=snapshot.scope} in
        state.snapshot <- {snapshot with pending=pending :: snapshot.pending})
   | PostToolUse {invocation;tool_name;output;_} ->
     (match take_pending state ~invocation ~tool_name with
      | None -> ()
      | Some pending ->
        if Recorder.current_runtime_id state.context = Some pending.runtime_id then
          (match record state ~handles:pending.handles ~runtime_id:pending.runtime_id ~tool_name
              ~occurrence:(Fact.Sdk_result {invocation;result=Fact.sdk_result output}) with
           | Ok _ -> () | Error error -> clear_if_current state pending.scope; on_error error))
   | PostToolUseFailure {invocation;tool_name;stage=Validation_before_execution;_} ->
     ignore (take_pending state ~invocation ~tool_name)
   | PostToolUseFailure {stage=Execution;_}
   | BeforeTurn _ | BeforeTurnParams _ | AfterTurn _ | OnStop _ | OnError _ | OnToolError _ -> ());
  Agent_core.Hooks.Continue
let native_started state ~runtime_id ~official_turn ~identity ~tool_name =
  let scope = state.snapshot.scope in
  if Recorder.current_runtime_id state.context <> Some runtime_id
  then Error (Invalid_evidence "native start differs from the selected physical attempt")
  else match record state ~handles:state.snapshot.active ~runtime_id ~tool_name
      ~occurrence:(Fact.Native_started {official_turn;identity}) with
    | Ok count -> Ok count
    | Error error -> refuse state scope error
