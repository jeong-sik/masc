(* #28809: an approved Gate resolution must reach a turn even when the turn
   was woken by a different stimulus, and must be able to preempt an in-flight
   source run while its one-shot grant is unspent. Covers the turn-start
   projection ([ready_hitl_resolution_peek]) and the post-tool boundary
   preemption ([hitl_replay_preemption_request] / [hitl_replay_yield_request]). *)
open Alcotest
open Masc
module Q = Keeper_event_queue

let () = Mirage_crypto_rng_unix.use_default ()

let temp_dir () =
  let path = Filename.temp_file "hitl_replay_delivery_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  ignore
    (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  Unix.putenv "MASC_BASE_PATH" dir;
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "test"));
  (match
     Keeper_owner_registry.install_from_store
       ~sw
       ~operation_runner:None
       ~on_turn_slot_released:None
       config
   with
   | Ok _ -> ()
   | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
  f config
;;

let unrouted = Keeper_continuation_channel.unrouted "test"

(* Durable intake is authorized by current metadata, so every test keeper
   that must accept a wake needs to exist first. *)
let create_keeper_exn ~config name =
  let json =
    `Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Error detail -> fail detail
  | Ok meta ->
    (match
       Keeper_owner_registry.create_meta
         ~base_path:config.Workspace_utils.base_path
         meta
     with
     | Ok _ -> ()
     | Error error ->
       fail (Keeper_owner_registry.command_error_to_string error))
;;

(* Submit + approve one grant. Resolving an approval for a keeper with no
   live lane durably enqueues its [Hitl_resolved] wake, which is exactly the
   queue state the projection and preemption read. *)
let approved_grant_fixture ~base_path ~keeper_name ~input =
  (match Keeper_approval_queue.install_persistence ~base_path with
   | Ok _ -> ()
   | Error error -> fail (Keeper_approval_queue.install_error_to_string error));
  let approval_id =
    match
      Keeper_approval_queue.submit_pending
        ~keeper_name
        ~tool_name:"external-effect"
        ~input
        ~base_path
        ()
    with
    | Ok submission -> submission.approval_id
    | Error error -> fail (Keeper_approval_queue.storage_error_to_string error)
  in
  (match
     Keeper_approval_queue.resolve_with_policy
       ~base_path
       ~id:approval_id
       ~decision:Keeper_approval_queue_rules_types.Decision.Approve
       ()
   with
   | Ok _ -> ()
   | Error error -> fail (Keeper_approval_queue.resolve_error_to_string error));
  approval_id
;;

let queue_length ~base_path ~keeper_name =
  match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
  | Ok pending -> Q.length pending
  | Error message -> fail message
;;

(* --- pure post-tool boundary decision --------------------------------- *)

let stimulus ~post_id ~urgency ~arrived_at ~payload : Q.stimulus =
  { post_id; urgency; arrived_at; payload }
;;

let queue_of stimuli = List.fold_left Q.enqueue Q.empty stimuli

let hitl_stimulus ~arrived_at ~approval_id =
  let resolution : Q.hitl_resolution =
    { approval_id; decision = Q.Hitl_approved; channel = unrouted }
  in
  stimulus
    ~post_id:(Q.hitl_resolution_post_id resolution)
    ~urgency:Q.Immediate
    ~arrived_at
    ~payload:(Q.Hitl_resolved resolution)
;;

let test_deliverable_resolution_preempts_source () =
  let source =
    stimulus ~post_id:"source" ~urgency:Q.Normal ~arrived_at:900. ~payload:Q.Bootstrap
  in
  let hitl = hitl_stimulus ~arrived_at:990. ~approval_id:"appr-preempt" in
  let request =
    Keeper_unified_turn.hitl_replay_preemption_request
      ~resolution_deliverable:(fun _ -> true)
      ~now:1000.
      (queue_of [ source; hitl ])
  in
  match request with
  | Some
      { Keeper_agent_run.reason = Keeper_agent_run.Durable_stimulus_waiting summary } ->
    check int "both durable stimuli remain visible" 2 summary.pending_count;
    (match summary.head with
     | Some selected ->
       check string
         "yield names the resolved approval as the next source"
         (Q.hitl_resolution_post_id
            { approval_id = "appr-preempt"
            ; decision = Q.Hitl_approved
            ; channel = unrouted
            })
         selected.post_id
     | None -> fail "hitl preemption lost its selected source");
    check (float 0.001) "selected-source age is exact" 10. summary.head_age_sec
  | Some { reason = Keeper_agent_run.Operation_queued } ->
    fail "hitl preemption was mislabeled as chat"
  | None -> fail "deliverable resolution did not preempt the in-flight source"
;;

let test_undeliverable_resolution_never_preempts () =
  let hitl = hitl_stimulus ~arrived_at:990. ~approval_id:"appr-spent" in
  check bool
    "spent or unready resolution keeps the source running"
    true
    (Option.is_none
       (Keeper_unified_turn.hitl_replay_preemption_request
          ~resolution_deliverable:(fun _ -> false)
          ~now:1000.
          (queue_of [ hitl ])))
;;

let test_queue_without_resolution_never_preempts () =
  let source =
    stimulus ~post_id:"source" ~urgency:Q.Normal ~arrived_at:900. ~payload:Q.Bootstrap
  in
  check bool
    "no queued resolution, no yield"
    true
    (Option.is_none
       (Keeper_unified_turn.hitl_replay_preemption_request
          ~resolution_deliverable:(fun _ -> true)
          ~now:1000.
          (queue_of [ source ])))
;;

(* --- durable deliverability -------------------------------------------- *)

let test_yield_request_tracks_grant_consumption () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let keeper_name = "hitl-preempt-keeper" in
  create_keeper_exn ~config keeper_name;
  let input = `Assoc [ "target", `String "hitl-preempt" ] in
  let approval_id = approved_grant_fixture ~base_path ~keeper_name ~input in
  (match Keeper_unified_turn.hitl_replay_yield_request ~base_path ~keeper_name with
   | Ok (Some { Keeper_agent_run.reason = Keeper_agent_run.Durable_stimulus_waiting _ })
     -> ()
   | Ok (Some { reason = Keeper_agent_run.Operation_queued }) ->
     fail "unspent grant was mislabeled as chat"
   | Ok None -> fail "unspent approved resolution did not request a yield"
   | Error message -> fail message);
  (match
     Keeper_approval_queue.consume_approved_resolution
       ~base_path
       ~id:approval_id
       ~keeper_name
       ~tool_name:"external-effect"
       ~input
   with
   | Ok (Keeper_approval_queue.Consumption_committed _) -> ()
   | Ok Keeper_approval_queue.Consumption_already_committed ->
     fail "grant was already consumed before the test consumed it"
   | Ok Keeper_approval_queue.Consumption_not_matching ->
     fail "exact grant did not match its own request"
   | Error error -> fail (Keeper_approval_queue.grant_error_to_string error));
  match Keeper_unified_turn.hitl_replay_yield_request ~base_path ~keeper_name with
  | Ok None -> ()
  | Ok (Some _) -> fail "spent grant preempted the source again"
  | Error message -> fail message
;;

(* --- turn-start projection --------------------------------------------- *)

let test_peek_projects_ready_resolution_without_consuming () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let keeper_name = "hitl-peek-keeper" in
  create_keeper_exn ~config keeper_name;
  let input = `Assoc [ "target", `String "hitl-peek" ] in
  let approval_id = approved_grant_fixture ~base_path ~keeper_name ~input in
  let before = queue_length ~base_path ~keeper_name in
  check int "resolution queued exactly one replay" 1 before;
  (match
     Keeper_heartbeat_stimulus_intake.ready_hitl_resolution_peek
       ~base_path
       ~keeper_name
   with
   | Some (resolution : Q.hitl_resolution) ->
     check string "peek returns the resolved approval" approval_id
       resolution.approval_id
   | None -> fail "ready resolution was not projected");
  check int "peek admits nothing from the queue" before
    (queue_length ~base_path ~keeper_name)
;;

let test_peek_skips_resolution_still_pending () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let keeper_name = "hitl-unready-keeper" in
  create_keeper_exn ~config keeper_name;
  (match Keeper_approval_queue.install_persistence ~base_path with
   | Ok _ -> ()
   | Error error -> fail (Keeper_approval_queue.install_error_to_string error));
  let approval_id =
    match
      Keeper_approval_queue.submit_pending
        ~keeper_name
        ~tool_name:"external-effect"
        ~input:(`Assoc [ "target", `String "hitl-unready" ])
        ~base_path
        ()
    with
    | Ok submission -> submission.approval_id
    | Error error -> fail (Keeper_approval_queue.storage_error_to_string error)
  in
  (* The approval is still pending, so a queued resolution event for it is
     not ready and must not be projected. *)
  (match
     Keeper_registry_event_queue.enqueue_hitl_resolution_durable_result
       ~base_path
       ~keeper_name
       ~approval_id
       ~decision:Q.Hitl_approved
       ~channel:unrouted
   with
   | Ok () -> ()
   | Error error ->
     fail
       (Keeper_registry_event_queue.hitl_resolution_enqueue_error_to_string
          error));
  check bool
    "pending approval is not projected"
    true
    (Option.is_none
       (Keeper_heartbeat_stimulus_intake.ready_hitl_resolution_peek
          ~base_path
          ~keeper_name))
;;

(* --- absent recipient --------------------------------------------------- *)

(* #31684: a resolution addressed to a Keeper that does not exist used to
   stay in the durable delivery store and replay the same permanent failure
   at every boot. Durable intake follows current metadata, so a name with no
   Keeper behind it settles the delivery at resolve time instead. *)
let test_retired_recipient_settles_delivery () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  (* No metadata is ever created for this name: the recipient does not
     exist. *)
  let keeper_name = "hitl-retired-keeper" in
  let input = `Assoc [ "target", `String "hitl-retired" ] in
  (* Resolving against the absent recipient must succeed (the fixture fails
     the test on a resolve error) and must not leave a durable delivery. *)
  ignore (approved_grant_fixture ~base_path ~keeper_name ~input);
  match Keeper_approval_queue.install_persistence ~base_path with
  | Ok report ->
    check int
      "retired recipient leaves nothing to replay"
      0
      report.replayed_deliveries;
    check int
      "retired recipient leaves no replay failures"
      0
      (List.length report.delivery_replay_failures)
  | Error error -> fail (Keeper_approval_queue.install_error_to_string error)
;;

let test_peek_none_on_empty_queue () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  check bool
    "empty queue projects nothing"
    true
    (Option.is_none
       (Keeper_heartbeat_stimulus_intake.ready_hitl_resolution_peek
          ~base_path
          ~keeper_name:"hitl-empty-keeper"))
;;

let () =
  run
    "keeper hitl replay delivery"
    [ ( "post-tool boundary preemption"
      , [ test_case
            "deliverable resolution preempts the in-flight source"
            `Quick
            test_deliverable_resolution_preempts_source
        ; test_case
            "undeliverable resolution never preempts"
            `Quick
            test_undeliverable_resolution_never_preempts
        ; test_case
            "queue without a resolution never preempts"
            `Quick
            test_queue_without_resolution_never_preempts
        ; test_case
            "yield request tracks durable grant consumption"
            `Quick
            test_yield_request_tracks_grant_consumption
        ] )
    ; ( "turn-start projection"
      , [ test_case
            "projects the ready resolution without consuming the queue"
            `Quick
            test_peek_projects_ready_resolution_without_consuming
        ; test_case
            "skips a resolution whose approval is still pending"
            `Quick
            test_peek_skips_resolution_still_pending
        ; test_case
            "projects nothing from an empty queue"
            `Quick
            test_peek_none_on_empty_queue
        ] )
    ; ( "retired recipient"
      , [ test_case
            "settles the delivery instead of replaying it forever"
            `Quick
            test_retired_recipient_settles_delivery
        ] )
    ]
;;
