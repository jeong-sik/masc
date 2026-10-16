module Plan = Keeper_tool_plan
module Nested = Keeper_composition_nested
module Executor = Keeper_tool_plan_executor
module Ledger = Keeper_skill_activation_ledger
module Recorder = Keeper_skill_activation_recorder
module Projection = Keeper_tool_plan_error_projection
module Node_order = struct
  type t = Plan.Node_id.t
  let compare left right = String.compare (Plan.Node_id.to_string left) (Plan.Node_id.to_string right)
end
module Node_map = Map.Make (Node_order)
module Node_set = Set.Make (Node_order)

type record_activation =
  invocation:Agent_core.Tool_contract.Invocation.t ->
  tool_name:string -> scope:Ledger.nested_composition_scope ->
  reference:Skill_reference.t -> (Ledger.record_outcome, Recorder.error) result

type admission =
  | Not_attempted
  | Admitted of string
  | Rejected of Executor.admission_rejection

type child =
  { call : Nested.call
  ; members : Node_set.t
  ; mutex : Eio.Mutex.t
  ; mutable admission : admission
  }

type t =
  { children : child list
  ; node_owners : child Node_map.t
  ; composition_run_id : Plan.Composition_run_id.t
  ; parent_invocation : Agent_core.Tool_contract.Invocation.t
  ; delivery_parent_tool_use_id : string
  ; tool_name : string
  ; record_activation : record_activation option
  }

type disposition = Not_started | Admission_rejected | Completed | Failed | Deferred | Partially_settled

let async_result_parent identity = "composition-result:" ^ Plan.Composition_run_id.to_string identity
;;

let create ?delivery_parent_tool_use_id ~calls ~composition_run_id ~parent_invocation ~tool_name ~record_activation () =
  let delivery_parent_tool_use_id = match delivery_parent_tool_use_id with Some id -> id
    | None -> Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation in
  let children = List.map (fun (call : Nested.call) ->
      let members = List.fold_left (fun members (_, id) -> Node_set.add id members) Node_set.empty call.node_mapping in
      { call; members; mutex = Eio.Mutex.create (); admission = Not_attempted }) calls in
  let node_owners = List.fold_left (fun index child -> Node_set.fold (fun id index ->
      if Node_map.mem id index then invalid_arg "compiled child leaf belongs to two scopes"
      else Node_map.add id child index) child.members index) Node_map.empty children in
  { children; node_owners; composition_run_id; parent_invocation; delivery_parent_tool_use_id; tool_name; record_activation }
;;

let rejection ~kind ~detail data : Executor.admission_rejection =
  { detail; data = `Assoc [ "kind", `String kind; "error", data ] }
;;

let child_invocation run child =
  let parent = Agent_core.Tool_contract.Invocation.tool_use_id run.parent_invocation in
  let alias = Plan.Node_id.to_string child.call.alias in
  let run_id = Plan.Composition_run_id.to_string run.composition_run_id in
  let tool_use_id = "composition-skill:" ^ Yojson.Safe.to_string
      (`List [ `String run_id; `String parent; `String alias ]) in
  let open Result in
  let ( let* ) = bind in
  let* scope = Ledger.nested_composition_scope ~parent_tool_use_id:run.delivery_parent_tool_use_id ~composition_run_id:run_id ~alias
        |> map_error (fun error -> Recorder.Activation_rejected error) in
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id
        ~turn:(Agent_core.Tool_contract.Invocation.turn run.parent_invocation)
        ~schedule:(Agent_core.Tool_contract.Invocation.schedule run.parent_invocation)
        ~completion:Agent_core.Tool_contract.Continue_after_success in
  Ok (tool_use_id, invocation, scope)
;;

let record_child run child =
  let record record_activation = Result.bind (child_invocation run child) (fun (identity,invocation,scope) ->
    Result.map (fun outcome -> identity,outcome)
      (record_activation ~invocation ~tool_name:run.tool_name ~scope ~reference:child.call.reference)) in
  match run.record_activation with
  | None -> Rejected (rejection ~kind:"nested_activation_context_unavailable"
      ~detail:"Nested dispatch requires the active turn's canonical Skill activation recorder." `Null)
  | Some record_activation ->
    match record record_activation with
    | Ok (identity,(Ledger.Recorded _ | Ledger.Already_recorded _)) -> Admitted identity
    | Error error -> Rejected (rejection ~kind:"nested_activation_rejected"
        ~detail:(Recorder.error_to_string error) (Recorder.error_to_yojson error))
;;

let restore_admissions run ~find_activation =
  List.iter (fun child ->
    let found = Result.bind (child_invocation run child) (fun (identity,invocation,scope) ->
      Result.map (fun activation -> identity,activation)
        (find_activation ~invocation ~tool_name:run.tool_name ~scope ~reference:child.call.reference)) in
    child.admission <- match found with
      | Ok (_,None) -> Not_attempted
      | Ok (identity,Some _) -> Admitted identity
      | Error error -> Rejected (rejection ~kind:"nested_original_activation_unavailable"
          ~detail:(Recorder.error_to_string error) (Recorder.error_to_yojson error))) run.children
;;

let check_original_admissions run ~child_history =
  List.fold_left (fun result child -> Result.bind result (fun () ->
    Result.bind (child_history ~node_ids:(Node_set.elements child.members)
      |> Result.map_error (fun error -> rejection ~kind:"nested_original_journal_unavailable"
        ~detail:(Keeper_tool_execution_journal.error_to_string error)
        (Keeper_tool_execution_journal.error_to_json error))) (fun history ->
    match child.admission with
    | Admitted _ -> Ok ()
    | Rejected error -> Error error
    | Not_attempted ->
      match history with
      | Keeper_tool_execution_journal.Untouched_child -> Ok ()
      | Keeper_tool_execution_journal.Admitted_child
      | Keeper_tool_execution_journal.Admission_unconfirmed -> Error (rejection
          ~kind:"nested_original_activation_missing"
          ~detail:"Original child evidence requires its exact retained activation before result reuse."
          (Nested.call_to_json child.call))))) (Ok ()) run.children
;;

let contains child node_id = Node_set.mem node_id child.members
;;

let admit_node run ~(node : Plan.node) =
  match Node_map.find_opt node.id run.node_owners with
  | None -> Ok ()
  | Some child ->
    Eio.Mutex.use_rw ~protect:true child.mutex (fun () ->
      (match child.admission with
       | Not_attempted -> child.admission <- record_child run child
       | Admitted _ | Rejected _ -> ());
      match child.admission with
      | Admitted _ -> Ok ()
      | Rejected rejection -> Error rejection
      | Not_attempted -> invalid_arg "child admission was not settled")
;;

let settled = function Ok nodes -> nodes | Error (failure : Executor.failure) -> failure.settled

let own_cause child = function
  | Ok _ -> None
  | Error (failure : Executor.failure) ->
    match failure.cause with
    | Executor.Tool_did_not_complete node when contains child node.node_id ->
      Some (`Assoc [ "kind", `String "tool_did_not_complete"
                  ; "node_id", `String (Plan.Node_id.to_string node.node_id) ])
    | Executor.Node_observation_failed { node; detail } when contains child node.node_id ->
      Some (`Assoc [ "kind", `String "node_observation_failed"
                  ; "node_id", `String (Plan.Node_id.to_string node.node_id); "detail", `String detail ])
    | Executor.Plan_execution_failed { node_id; error; schedule = _ } when contains child node_id ->
      Some (`Assoc [ "kind", `String "plan_execution_failed"
                  ; "node_id", `String (Plan.Node_id.to_string node_id)
                  ; "error", Projection.plan_execution_error_to_json error ])
    | Executor.Tool_did_not_complete _ | Executor.Node_observation_failed _
    | Executor.Plan_execution_failed _ | Executor.Run_journal_rejected _
    | Executor.Outer_completion_mismatch _ -> None
;;

let disposition child nodes execution =
  match child.admission with
  | Not_attempted -> Not_started
  | Rejected _ -> Admission_rejected
  | Admitted _ ->
    let own_boundary_failed = match execution with
      | Error (failure : Executor.failure) ->
        (match failure.cause with
         | Executor.Node_observation_failed { node; detail = _ } -> contains child node.node_id
         | Executor.Plan_execution_failed { node_id; error = _; schedule = _ } -> contains child node_id
         | Executor.Tool_did_not_complete _ | Executor.Run_journal_rejected _
         | Executor.Outer_completion_mismatch _ -> false)
      | Ok _ -> false in
    if own_boundary_failed || List.exists (fun (node : Executor.node_result) ->
        match node.result, node.output_validation_error with
        | Tool_result.Failed _, _ | Tool_result.Completed _, Some _ -> true
        | Tool_result.Completed _, None | Tool_result.Deferred _, _ -> false) nodes then Failed
    else if List.exists (fun (node : Executor.node_result) ->
        match node.result with Tool_result.Deferred _ -> true | Tool_result.Completed _ | Tool_result.Failed _ -> false) nodes then Deferred
    else if List.length nodes = List.length child.call.node_mapping then Completed
    else Partially_settled
;;

let disposition_to_string = function
  | Not_started -> "not_started" | Admission_rejected -> "admission_rejected"
  | Completed -> "completed" | Failed -> "failed" | Deferred -> "deferred"
  | Partially_settled -> "partially_settled"
;;

let export_error = function
  | Plan.Producer_unavailable node_id -> `Assoc
      [ "kind", `String "producer_unavailable"; "node_id", `String (Plan.Node_id.to_string node_id) ]
  | Plan.Producer_invalid error -> `Assoc
      [ "kind", `String "producer_invalid"; "error", Projection.plan_execution_error_to_json error ]
  | Plan.Export_pointer_unavailable error -> `Assoc
      [ "kind", `String "pointer_unavailable"; "error", Projection.pointer_resolution_error_to_json error ]
;;

let evidence_to_json run ~plan ~execution =
  let index = List.fold_left (fun index (node : Executor.node_result) -> Node_map.add node.node_id node index)
      Node_map.empty (settled execution) in
  `List (List.map (fun child ->
    let nodes = List.filter_map (fun (_, id) -> Node_map.find_opt id index) child.call.node_mapping in
    let cause = own_cause child execution in
    let lookup id = if not (contains child id) then None else
        match Node_map.find_opt id index with
        | None -> None
        | Some node ->
        match node.result, node.output_validation_error with
        | Tool_result.Completed payload, None -> Some payload.data
        | Tool_result.Completed _, Some _ | Tool_result.Failed _, _ | Tool_result.Deferred _, _ -> None in
    let admission = match child.admission with
      | Not_attempted -> `Null
      | Admitted id -> `Assoc [ "skill_tool_use_id", `String id ]
      | Rejected rejection -> `Assoc [ "rejection", rejection.data ] in
    let node_states = List.map (fun (source, id) ->
        let fields = [ "source", `String (Plan.Node_id.to_string source); "node_id", `String (Plan.Node_id.to_string id) ] in
        let state = match Node_map.find_opt id index with
          | None -> [ "settled", `Bool false; "disposition", `Null ]
          | Some node ->
            [ "settled", `Bool true; "disposition", `String (Tool_result.string_of_disposition node.result)
            ; "tool_use_id", `String node.tool_use_id
            ; "failure_effect_disposition", (match node.failure_effect_disposition with None -> `Null
                | Some disposition -> `String (Tool_result.failure_effect_disposition_to_string disposition))
            ; "output_validation_error", (match node.output_validation_error with None -> `Null
                | Some error -> Projection.plan_execution_error_to_json error) ] in
        `Assoc (fields @ state)) child.call.node_mapping in
    let exports = `Assoc (List.map (fun (export : Plan.export) -> export.name,
        match Plan.resolve_export plan ~lookup export with
        | Ok value -> `Assoc [ "available", `Bool true; "value", value ]
        | Error error -> `Assoc [ "available", `Bool false; "error", export_error error ]) child.call.exports) in
    `Assoc [ "scope", Nested.call_to_json child.call
           ; "admission", admission
           ; "disposition", `String (disposition_to_string (disposition child nodes execution))
           ; "cause", (match cause with None -> `Null | Some cause -> cause)
           ; "nodes", `List node_states; "exports", exports ]) run.children)
;;
