type criticality =
  | Durability_critical
  | Best_effort

type terminal_effect =
  | Checkpoint_store
  | Execution_receipt
  | Owner_meta
  | Lifecycle_projection
  | Metrics_snapshot
  | Activity_graph
  | Decision_record
  | Usage_metrics
  | Terminal_fsm_projection

let all =
  [ Checkpoint_store
  ; Execution_receipt
  ; Owner_meta
  ; Lifecycle_projection
  ; Metrics_snapshot
  ; Activity_graph
  ; Decision_record
  ; Usage_metrics
  ; Terminal_fsm_projection
  ]
;;

let criticality = function
  | Checkpoint_store
  | Execution_receipt
  | Owner_meta ->
    Durability_critical
  | Lifecycle_projection
  | Metrics_snapshot
  | Activity_graph
  | Decision_record
  | Usage_metrics
  | Terminal_fsm_projection ->
    Best_effort
;;

let effect_label = function
  | Checkpoint_store -> "checkpoint_store"
  | Execution_receipt -> "execution_receipt"
  | Owner_meta -> "owner_meta"
  | Lifecycle_projection -> "lifecycle_projection"
  | Metrics_snapshot -> "metrics_snapshot"
  | Activity_graph -> "activity_graph"
  | Decision_record -> "decision_record"
  | Usage_metrics -> "usage_metrics"
  | Terminal_fsm_projection -> "terminal_fsm_projection"
;;

let criticality_label = function
  | Durability_critical -> "durability_critical"
  | Best_effort -> "best_effort"
;;

let failure_blocks_product_success terminal_effect =
  match criticality terminal_effect with
  | Durability_critical -> true
  | Best_effort -> false
;;

let run_best_effort ~terminal_effect ~on_error f =
  match criticality terminal_effect with
  | Durability_critical ->
    invalid_arg
      (Printf.sprintf
         "Keeper_terminal_effect_policy.run_best_effort: %s is %s"
         (effect_label terminal_effect)
         (criticality_label (criticality terminal_effect)))
  | Best_effort ->
    (match f () with
     | () -> ()
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn -> on_error exn)
;;

let matrix_to_yojson () =
  `List
    (List.map
       (fun terminal_effect ->
          let criticality = criticality terminal_effect in
          `Assoc
            [ "effect", `String (effect_label terminal_effect)
            ; "criticality", `String (criticality_label criticality)
            ; ( "failure_blocks_product_success"
              , `Bool (failure_blocks_product_success terminal_effect) )
            ])
       all)
;;
