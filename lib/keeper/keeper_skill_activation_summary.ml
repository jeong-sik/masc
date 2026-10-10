open Keeper_skill_activation_types

let empty_summary invalid_transitions =
  { instruction_invocations = 0
  ; skill_bodies_served = 0
  ; skill_resources_served = 0
  ; instruction_provider_deliveries = 0
  ; instruction_official_client_handoffs = 0
  ; instruction_actions_observed = 0
  ; composition_invocations = 0
  ; composition_provider_deliveries = 0
  ; composition_official_client_handoffs = 0
  ; composition_actions_observed = 0
  ; invalid_transitions
  }
;;

let summarize ~activations ~transition_rejections =
  List.fold_left
    (fun summary activation ->
       let provider_delivered, official_client_handoff =
         match activation.delivery with
         | Some { boundary = Model_response _; _ } -> 1, 0
         | Some { boundary = Official_client_result_handoff _; _ } -> 0, 1
         | None -> 0, 0
       in
       let actions = List.length activation.actions in
       match activation.invocation with
       | Instruction_invocation { served_content; _ } ->
         let skill_bodies_served, skill_resources_served =
           match served_content with
           | Skill_body _ -> summary.skill_bodies_served + 1, summary.skill_resources_served
           | Skill_resource _ ->
             summary.skill_bodies_served, summary.skill_resources_served + 1
         in
         { summary with
           instruction_invocations = summary.instruction_invocations + 1
         ; skill_bodies_served
         ; skill_resources_served
         ; instruction_provider_deliveries =
             summary.instruction_provider_deliveries + provider_delivered
         ; instruction_official_client_handoffs =
             summary.instruction_official_client_handoffs
             + official_client_handoff
         ; instruction_actions_observed =
             summary.instruction_actions_observed + actions
         }
       | Composition_invocation _ ->
         { summary with
           composition_invocations = summary.composition_invocations + 1
         ; composition_provider_deliveries =
             summary.composition_provider_deliveries + provider_delivered
         ; composition_official_client_handoffs =
             summary.composition_official_client_handoffs
             + official_client_handoff
         ; composition_actions_observed =
             summary.composition_actions_observed + actions
         })
    (empty_summary (List.length transition_rejections))
    activations
;;

let summary_to_yojson summary =
  `Assoc
    [ "instruction_invocations", `Int summary.instruction_invocations
    ; "skill_bodies_served", `Int summary.skill_bodies_served
    ; "skill_resources_served", `Int summary.skill_resources_served
    ; ( "instruction_provider_deliveries"
      , `Int summary.instruction_provider_deliveries )
    ; ( "instruction_official_client_handoffs"
      , `Int summary.instruction_official_client_handoffs )
    ; "instruction_actions_observed", `Int summary.instruction_actions_observed
    ; "composition_invocations", `Int summary.composition_invocations
    ; ( "composition_provider_deliveries"
      , `Int summary.composition_provider_deliveries )
    ; ( "composition_official_client_handoffs"
      , `Int summary.composition_official_client_handoffs )
    ; "composition_actions_observed", `Int summary.composition_actions_observed
    ; "invalid_transitions", `Int summary.invalid_transitions
    ]
;;

let scope_of_activation (activation : activation) =
  { snapshot_revision = activation.snapshot_revision
  ; turn_ref = activation.turn_ref
  ; invocation_runtime_id = activation.runtime_id
  ; reference =
      Skill_reference.make
        ~identity:activation.identity
        ~content_revision:activation.content_revision
  }
;;

let equal_summary_scope left right =
  Skill_catalog_snapshot.equal_snapshot_revision
    left.snapshot_revision
    right.snapshot_revision
  && Ids.Turn_ref.equal left.turn_ref right.turn_ref
  && String.equal left.invocation_runtime_id right.invocation_runtime_id
  && Skill_reference.equal left.reference right.reference
;;

let runtime_counts runtime_ids =
  List.fold_left
    (fun counts runtime_id ->
       let rec increment reversed = function
         | [] -> List.rev_append reversed [ { runtime_id; count = 1 } ]
         | ({ runtime_id = known; count } as current) :: rest ->
           if String.equal runtime_id known
           then List.rev_append reversed ({ current with count = count + 1 } :: rest)
           else increment (current :: reversed) rest
       in
       increment [] counts)
    []
    runtime_ids
;;

let summarize_by_scope ~activations:all_activations ~transition_rejections:all_rejections =
  let scopes =
    List.fold_left
      (fun scopes activation ->
         let scope = scope_of_activation activation in
         if List.exists (equal_summary_scope scope) scopes
         then scopes
         else scopes @ [ scope ])
      []
      all_activations
  in
  List.map
    (fun scope ->
       let activations =
         List.filter
           (fun activation ->
              equal_summary_scope scope (scope_of_activation activation))
           all_activations
       in
       let invocation_ids =
         List.map (fun activation -> activation.skill_tool_use_id) activations
       in
       let transition_rejections =
         List.filter
           (fun rejection ->
              List.mem (rejection_skill_tool_use_id rejection) invocation_ids)
           all_rejections
       in
       let provider_delivery_runtime_counts =
         activations
         |> List.filter_map (fun activation ->
              match activation.delivery with
              | Some { boundary = Model_response _; runtime_id; _ } ->
                Some runtime_id
              | Some { boundary = Official_client_result_handoff _; _ }
              | None -> None)
         |> runtime_counts
       in
       let official_client_handoff_runtime_counts =
         activations
         |> List.filter_map (fun activation ->
              match activation.delivery with
              | Some
                  { boundary = Official_client_result_handoff _; runtime_id; _ } ->
                Some runtime_id
              | Some { boundary = Model_response _; _ }
              | None -> None)
         |> runtime_counts
       in
       let action_runtime_counts =
         activations
         |> List.concat_map (fun activation ->
              List.map (fun (action : action) -> action.runtime_id) activation.actions)
         |> runtime_counts
       in
       { scope
       ; summary = summarize ~activations ~transition_rejections
       ; provider_delivery_runtime_counts
       ; official_client_handoff_runtime_counts
       ; action_runtime_counts
       })
    scopes
;;

let scoped_summary_to_yojson scoped =
  `Assoc
    [ ( "scope"
      , `Assoc
          [ ( "snapshot_revision"
            , `String
                (Skill_catalog_snapshot.snapshot_revision_to_string
                   scoped.scope.snapshot_revision) )
          ; "turn_ref", Ids.Turn_ref.to_yojson scoped.scope.turn_ref
          ; "invocation_runtime_id", `String scoped.scope.invocation_runtime_id
          ; "reference", Skill_reference.to_yojson scoped.scope.reference
          ] )
    ; "summary", summary_to_yojson scoped.summary
    ; ( "provider_delivery_runtime_counts"
      , `List
          (List.map
             (fun runtime ->
                `Assoc
                  [ "runtime_id", `String runtime.runtime_id
                  ; "count", `Int runtime.count
                  ])
             scoped.provider_delivery_runtime_counts) )
    ; ( "official_client_handoff_runtime_counts"
      , `List
          (List.map
             (fun runtime ->
                `Assoc
                  [ "runtime_id", `String runtime.runtime_id
                  ; "count", `Int runtime.count
                  ])
             scoped.official_client_handoff_runtime_counts) )
    ; ( "action_runtime_counts"
      , `List
          (List.map
             (fun runtime ->
                `Assoc
                  [ "runtime_id", `String runtime.runtime_id
                  ; "count", `Int runtime.count
                  ])
             scoped.action_runtime_counts) )
    ]
;;
