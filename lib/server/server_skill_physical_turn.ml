module Ledger = Keeper_skill_activation_ledger
module Delivery = Keeper_skill_async_delivery
module Action = Keeper_skill_async_action
module Discovery = Keeper_skill_activation_discovery
module String_set = Set.Make (String)

type origin =
  { trace_id : Keeper_id.Trace_id.t
  ; ledger_revision : Ledger.ledger_revision
  ; activations : Ledger.activation list
  ; deliveries : Delivery.t list
  ; actions : Action.t list
  }

let matching_origin ~turn_ref ~trace_id ledger =
  let deliveries = Ledger.async_result_deliveries ledger
    |> List.filter (fun (item : Delivery.t) ->
      Ids.Turn_ref.equal item.physical_turn_ref turn_ref) in
  let actions = Ledger.async_actions ledger
    |> List.filter (fun (item : Action.t) ->
      Ids.Turn_ref.equal item.physical_turn_ref turn_ref) in
  let child_ids = List.fold_left
    (fun ids (delivery : Delivery.t) ->
      List.fold_left (fun ids (child : Delivery.child_activation) ->
        String_set.add child.skill_tool_use_id ids) ids delivery.child_activations)
    String_set.empty deliveries in
  let activations = Ledger.activations ledger
    |> List.filter (fun (item : Ledger.activation) ->
      Ids.Turn_ref.equal item.turn_ref turn_ref
      || String_set.mem item.skill_tool_use_id child_ids) in
  match activations, deliveries, actions with
  | [], [], [] -> None
  | _ -> Some {trace_id; ledger_revision=Ledger.revision ledger; activations; deliveries; actions}

let origin_to_json origin =
  `Assoc
    [ "trace_id", `String (Keeper_id.Trace_id.to_string origin.trace_id)
    ; "ledger_revision", `String (Ledger.ledger_revision_to_string origin.ledger_revision)
    ; "activations", `List (List.map Ledger.activation_to_yojson origin.activations)
    ; "async_result_deliveries", `List (List.map Delivery.to_json origin.deliveries)
    ; "async_actions", `List (List.map Action.to_json origin.actions)
    ]

let project ~config ~turn_ref =
  let observed = Discovery.scan config ~init:[]
    ~observe:(fun origins ~trace_id ledger ->
      match matching_origin ~turn_ref ~trace_id ledger with
      | None -> origins
      | Some origin -> origin :: origins) in
  let origins = List.sort (fun left right ->
    String.compare (Keeper_id.Trace_id.to_string left.trace_id)
      (Keeper_id.Trace_id.to_string right.trace_id)) observed.value in
  `Assoc
    [ "schema", `String "masc.dashboard.skill-physical-turn/v1"
    ; "turn_ref", Ids.Turn_ref.to_yojson turn_ref
    ; "origins", `List (List.map origin_to_json origins)
    ; "coverage", `Assoc
        [ "scope", `String (Server_skill_evidence.activation_scope_to_string observed.scope)
        ; "sessions_inspected", `Int observed.sessions_inspected
        ; "ledgers_loaded", `Int observed.ledgers_loaded
        ; "gaps", `List (List.map Server_skill_evidence.activation_gap_to_yojson observed.gaps)
        ]
    ]

let project_string ~config raw =
  Result.map (fun turn_ref -> project ~config ~turn_ref) (Ids.Turn_ref.of_string raw)
