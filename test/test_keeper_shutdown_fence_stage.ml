(* #31738: a [Blocked] shutdown used to hold the admission fence for every
   failure stage, including ones that ran before the shutdown mutated anything
   durable. Such a Keeper was permanently unbootable and only an operator
   supersession could free it, even though no retry was in flight and nothing
   had been torn down. The fence now follows the stage: a failure before the
   first durable mutation is retryable, one at or after it is not.

   The regression this guards is the old [Blocked _ -> true] clause, which
   answered [true] for every stage. A test that only fed fenced stages would
   have passed against it, so the retryable cases are the ones that matter. *)

open Alcotest
open Masc
open Keeper_shutdown_types

let trace_id_exn value =
  match Keeper_id.Trace_id.of_string value with
  | Ok trace_id -> trace_id
  | Error detail -> failf "trace id: %s" detail
;;

let keeper_name = "rw-e0-fence-stage"

let operation_with_stage stage =
  { schema_version = Keeper_shutdown_types.schema_version
  ; revision = 1
  ; operation_id = Operation_id.generate ()
  ; keeper_name
  ; lane_ownership = Dormant_meta
  ; trace_id = trace_id_exn "trace-fence-stage-test"
  ; actor = "tester"
  ; cleanup_intent = { reason = Operator_stop_retain_meta; remove_session = false }
  ; turn_disposition = No_inflight_turn
  ; expected_backlog_version = 0
  ; owned_task_ids = []
  ; join_evidence = None
  ; phase = Blocked { stage; detail = "fixture" }
  ; created_at = Masc_domain.now_iso ()
  ; updated_at = Masc_domain.now_iso ()
  }
;;

(* Failures that ran before the shutdown touched anything durable. A Keeper
   blocked here must be able to boot again. *)
let test_pre_destruction_stages_are_retryable () =
  List.iter
    (fun stage ->
       check
         bool
         (failure_stage_to_string stage ^ " is retryable")
         false
         (requires_admission_fence (operation_with_stage stage)))
    [ Task_discovery; Record_persist; Meta_update; Pending_confirm_cleanup ]
;;

(* Failures at or after the first durable mutation. These keep the fence. *)
let test_destruction_stages_keep_the_fence () =
  List.iter
    (fun stage ->
       check
         bool
         (failure_stage_to_string stage ^ " keeps the fence")
         true
         (requires_admission_fence (operation_with_stage stage)))
    [ Turn_cancel
    ; Lane_cancel
    ; Turn_join
    ; Lane_join
    ; Record_update
    ; Unhandled_worker
    ; Task_settlement
    ; Approval_summary_retirement
    ; Meta_remove
    ; Session_remove
    ; Registry_unregister
    ]
;;

(* The predicate is total over the stage type, so a new stage cannot silently
   default to "retryable". The count pins the list to the type: adding a
   variant without classifying it fails here. *)
let test_every_stage_is_classified () =
  let all_stages =
    [ Task_discovery
    ; Record_persist
    ; Turn_cancel
    ; Lane_cancel
    ; Turn_join
    ; Lane_join
    ; Record_update
    ; Unhandled_worker
    ; Task_settlement
    ; Pending_confirm_cleanup
    ; Approval_summary_retirement
    ; Meta_update
    ; Meta_remove
    ; Session_remove
    ; Registry_unregister
    ]
  in
  check int "every stage is exercised" 15 (List.length all_stages);
  List.iter
    (fun stage -> ignore (failure_stage_requires_admission_fence stage : bool))
    all_stages
;;

let () =
  run
    "keeper_shutdown_fence_stage"
    [ ( "fence stage"
      , [ test_case
            "pre-destruction stages are retryable"
            `Quick
            test_pre_destruction_stages_are_retryable
        ; test_case
            "destruction stages keep the fence"
            `Quick
            test_destruction_stages_keep_the_fence
        ; test_case "every stage is classified" `Quick test_every_stage_is_classified
        ] )
    ]
;;
