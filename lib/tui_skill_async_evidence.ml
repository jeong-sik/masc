module Action = Keeper_skill_async_action
module Occurrences = Map.Make (String)

type action_group =
  { first : Action.t
  ; additional_links : Action.t list
  }

type t =
  { result_deliveries : Keeper_skill_async_delivery.t list
  ; action_link_count : int
  ; actions : action_group list
  }

let project (evidence : Keeper_skill_activation_ledger.async_evidence) =
  let keys, groups =
    List.fold_left
      (fun (keys, groups) action ->
        let key = Action.occurrence_identity action in
        match Occurrences.find_opt key groups with
        | None ->
          key :: keys,
          Occurrences.add key { first = action; additional_links = [] } groups
        | Some group ->
          keys,
          Occurrences.add key
            { group with additional_links = action :: group.additional_links }
            groups)
      ([], Occurrences.empty)
      evidence.action_observations
  in
  { result_deliveries = evidence.result_deliveries
  ; action_link_count = List.length evidence.action_observations
  ; actions =
      List.rev_map
        (fun key ->
          let group = Occurrences.find key groups in
          { group with additional_links = List.rev group.additional_links })
        keys
  }
