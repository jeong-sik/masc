open Alcotest
module U = Yojson.Safe.Util
module Keeper_chat_store = Masc.Keeper_chat_store
module Keeper_external_attention = Masc.Keeper_external_attention
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_owner_registry = Masc.Keeper_owner_registry
module Keeper_registry = Masc.Keeper_registry
module Keeper_shutdown_types = Masc.Keeper_shutdown_types
module Keeper_shutdown_store = Masc.Keeper_shutdown_store
module Keeper_types_profile = Masc.Keeper_types_profile
module Otel_metric_store = Masc.Otel_metric_store
module Server_keeper_waiting_inventory = Masc.Server_keeper_waiting_inventory

(* Fixture tick for create and modify: the runner's floor tick, below every
   interval these fixtures declare, so the runner-tick check never refuses one
   of them. *)
let runner_tick_sec = 1.0

let () = ignore Operator_tool.force_link

let temp_dir () =
  let path = Filename.temp_file "keeper_waiting_inventory_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path)
      else Sys.remove path
  in
  match rm dir with
  | () -> ()
  | exception Sys_error msg -> fail ("rm_rf failed: " ^ msg)
  | exception Unix.Unix_error (err, fn, arg) ->
    fail
      (Printf.sprintf
         "rm_rf failed: %s %s %s"
         fn
         arg
         (Unix.error_message err))
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
   | Ok 0 -> ()
   | Ok count -> failf "expected empty owner inventory, got %d owners" count
   | Error error ->
     fail
       ("owner inventory install failed: "
        ^ Keeper_owner_registry.install_error_to_string error));
  f config
;;

(* [sandbox_profile] / [network_mode] are keeper TOML fields, not keeper meta
   JSON fields, and the meta parser rejects anything outside its schema — so
   the fixture states only the name and lets [meta_of_json_fixture] fill in
   the rest. *)
let keeper_meta_fixture keeper_name =
  Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String keeper_name ])
;;

let ensure_keeper config keeper_name =
  let meta =
    match keeper_meta_fixture keeper_name with
    | Ok meta -> meta
    | Error detail -> fail ("keeper meta fixture failed: " ^ detail)
  in
  match
    Keeper_owner_registry.create_meta
      ~base_path:config.Workspace_utils_backend_setup.base_path
      meta
  with
  | Ok (Some _) -> ()
  | Ok None -> fail "owner create did not persist keeper meta"
  | Error err ->
    fail
      ("owner create failed: " ^ Keeper_owner_registry.command_error_to_string err)
;;

let keeper_meta_exn config keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Ok (Some meta) -> meta
  | Ok None -> fail ("keeper meta missing: " ^ keeper_name)
  | Error err -> fail ("read_meta failed: " ^ err)
;;

let stimulus ~post_id ~arrived_at payload : Keeper_event_queue.stimulus =
  { post_id; urgency = Keeper_event_queue.Normal; arrived_at; payload }
;;

let queue_of_list stimuli =
  List.fold_left Keeper_event_queue.enqueue Keeper_event_queue.empty stimuli
;;

let find_keeper json keeper_name =
  json
  |> U.member "keepers"
  |> U.to_list
  |> List.find_opt (fun row ->
    String.equal keeper_name U.(row |> member "keeper_name" |> to_string))
;;

let json_int_member name json = U.(json |> member name |> to_int)
let json_string_member name json = U.(json |> member name |> to_string)
let json_bool_member name json = U.(json |> member name |> to_bool)
let json_string_list_member name json = U.(json |> member name |> to_list |> List.map to_string)

let metric_value name ~labels =
  Otel_metric_store.metric_value_or_zero name ~labels ()
;;

let check_metric_float label name ~labels expected =
  check bool label true (Float.equal expected (metric_value name ~labels))
;;

let human id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Human_operator; display_name = None }
;;

let automated id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Automated_actor; display_name = None }
;;

let schedule_payload =
  `Assoc
    [ "kind", `String "keeper.waiting_test"
    ; "body", `Assoc [ "message", `String "wait for schedule" ]
    ]
;;

let external_attention_item ~keeper_name index : Keeper_external_attention.item =
  let dedupe_key = Printf.sprintf "waiting-inventory-external:%s:%d" keeper_name index in
  { event_id = Keeper_external_attention.event_id_of_dedupe_key dedupe_key
  ; dedupe_key
  ; keeper_name
  ; conversation =
      { conversation_id = Printf.sprintf "conversation-%d" index
      ; surface = Keeper_external_attention.Agent
      }
  ; external_message = None
  ; source_label = "agent"
  ; actor =
      { actor_id = Some (Printf.sprintf "actor-%d" index)
      ; display_name = None
      ; authority = Keeper_chat_store.External
      }
  ; urgency = Keeper_external_attention.Ambient
  ; content_preview = Printf.sprintf "attention %d" index
  ; content_ref = None
  ; received_at = 100.0 +. Float.of_int index
  ; metadata = []
  }
;;

let create_schedule_exn ?(payload = schedule_payload) config ~schedule_id ~scheduled_by =
  match
    Schedule_service.create
      config
      ~runner_tick_sec
      ~now:100.0
      ~schedule_id
      ~requested_at:100.0
      ~requested_by:(human "operator")
      ~scheduled_by
      ~due_at:200.0
      ~payload
      ~source:Schedule_domain.Operator_request
      ()
  with
  | Ok request -> request
  | Error err ->
    fail ("schedule create failed: " ^ Schedule_service.service_error_to_string err)
;;

(* The row a settled async composition puts in front of an operator.

   The dashboard reads these fields by name -- [wake_producer] goes straight
   into the queue row, [source] picks the lane stage, and [detail] is what the
   inventory panel expands -- so the shape is a wire contract, not internal
   naming. Pinned here because a composition that finishes and shows up as a
   blank row is the same loss as not being announced at all. *)
let test_settled_composition_row_names_what_finished () =
  with_workspace
  @@ fun config ->
  let keeper_name = "composition-inventory-keeper" in
  ensure_keeper config keeper_name;
  let completion =
    { Keeper_event_queue.cc_request_id = "kmsg-bbb"
    ; cc_tool = "keeper_compose_memory-background"
    ; cc_terminal = Keeper_event_queue.Composition_failed "node search: store unavailable"
    }
  in
  Keeper_event_queue_persistence.persist
    ~base_path:config.Workspace_utils_backend_setup.base_path
    ~keeper_name
    (queue_of_list
       [ stimulus
           ~post_id:(Keeper_event_queue.composition_completion_post_id completion)
           ~arrived_at:100.0
           (Keeper_event_queue.Composition_completed completion)
       ]);
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  match find_keeper json keeper_name with
  | None -> fail "keeper row missing"
  | Some keeper ->
    (match U.(keeper |> member "waiting_on" |> to_list) with
     | row :: _ ->
       (* The lane stage the dashboard picks. A composition result waits in the
          Keeper's own event queue like every other stimulus. *)
       check string "the row sits in the event queue lane" "event_queue_pending"
         (json_string_member "source" row);
       check string "the producer names the composition broker" "keeper_composition"
         (json_string_member "wake_producer" row);
       check string "the row says which composition and how it ended"
         "keeper_compose_memory-background 실패 · kmsg-bbb"
         (json_string_member "what" row);
       let detail = U.member "detail" row in
       check string "the typed payload label survives" "keeper_composition_completed"
         (json_string_member "payload_kind" detail);
       (* The two fields an operator needs to go read the result itself. *)
       check string "the request id to read the result with" "kmsg-bbb"
         (json_string_member "composition_request_id" detail);
       check string "and the tool that produced it"
         "keeper_compose_memory-background"
         (json_string_member "composition_tool" detail)
     | [] -> fail "the settled composition put no row in front of the operator")
;;

let test_event_queue_pending_is_visible () =
  with_workspace
  @@ fun config ->
  let keeper_name = "waiting-inventory-keeper" in
  ensure_keeper config keeper_name;
  let pending =
    stimulus ~post_id:"pending-1" ~arrived_at:100.0 Keeper_event_queue.Bootstrap
  in
  Keeper_event_queue_persistence.persist
    ~base_path:config.Workspace_utils_backend_setup.base_path
    ~keeper_name
    (queue_of_list [ pending ]);
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check_metric_float "event pending metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "keeper"; "source", "event_queue_pending" ]
    1.0;
  check_metric_float "waiting keeper metric"
    Otel_metric_store.metric_keeper_waiting_keeper_count
    ~labels:[ "state", "waiting" ]
    1.0;
  check bool "pending age metric positive" true
    (metric_value
       Otel_metric_store.metric_keeper_waiting_age_seconds
       ~labels:[ "scope", "keeper"; "source", "event_queue_pending" ]
     > 0.0);
  check string "schema" "masc.dashboard.keeper_waiting_inventory.v4"
    (json_string_member "schema" json);
  check int "one keeper" 1 (json_int_member "keeper_count" json);
  check int "one waiting keeper" 1 (json_int_member "waiting_keeper_count" json);
  check int "one row" 1 (json_int_member "row_count" json);
  check int "flat total counts keeper and global rows" 1
    (json_int_member "total_row_count" json);
  (match U.(json |> member "rows" |> to_list) with
   | [ flat_row ] ->
     check string "flat row keeps its keeper" keeper_name
       (json_string_member "keeper_name" flat_row);
     check string "flat row keeps its next action" "keeper_drain_event_queue"
       (json_string_member "next_action" flat_row)
   | rows ->
     fail
       (Printf.sprintf
          "expected one flat row, got %d"
          (List.length rows)));
  check bool "fleet oldest age is positive" true
    (U.(json |> member "oldest_age_seconds" |> to_float) > 0.0);
  match find_keeper json keeper_name with
  | None -> fail "keeper row missing"
  | Some keeper ->
    check string "state" "waiting" (json_string_member "state" keeper);
    check (list string) "the state names what the Keeper waits on"
      [ "event_queue_pending" ] (json_string_list_member "state_sources" keeper);
    check int "waiting count" 1 (json_int_member "waiting_count" keeper);
    check int "pending source" 1 U.(keeper |> member "sources" |> member "event_queue_pending" |> to_int);
    (match U.(keeper |> member "waiting_on" |> to_list) with
     | pending_row :: _ ->
       check string "pending wake producer" "keeper_supervisor"
         (json_string_member "wake_producer" pending_row);
       check string "operator sentence names the bootstrap wake" "기동 직후 첫 턴"
         (json_string_member "what" pending_row);
       let detail = U.member "detail" pending_row in
       check string "public row retains typed payload label" "bootstrap"
         (json_string_member "payload_kind" detail);
       check bool "public row does not enumerate the exact event payload" true
         (U.member "payload" detail = `Null);
       (* The row carries the exact-entry address the operator boundary
          resolves, so the inventory is the only queue projection a control
          surface needs. *)
       let source_ref = json_string_member "source_ref" detail in
       let source_incarnation = json_string_member "source_incarnation" detail in
       check string "source_ref is the typed source snapshot digest"
         (Keeper_event_queue_state.source_snapshot_ref pending)
         source_ref;
       let state =
         match
           Keeper_event_queue_persistence.load_state_result
             ~base_path:config.Workspace_utils_backend_setup.base_path
             ~keeper_name
         with
         | Ok state -> state
         | Error detail -> fail ("durable queue state read failed: " ^ detail)
       in
       (match Keeper_event_queue_state.pending_selections state with
        | [ selection ] ->
          check string "source_incarnation is the entry's admitted revision"
            (Int64.to_string selection.admitted_revision)
            source_incarnation
        | selections ->
          failf "expected one pending selection, got %d" (List.length selections));
       (match
          Keeper_event_queue_state.resolve_pending_selection
            ~source_ref
            ~source_incarnation:(Int64.of_string source_incarnation)
            state
        with
        | Ok selection ->
          check string "resolved selection is the queued stimulus"
            pending.Keeper_event_queue.post_id
            selection.Keeper_event_queue_state.source.Keeper_event_queue.post_id
        | Error detail -> fail ("row address did not resolve: " ^ detail))
     | rows -> failf "expected one queue row, got %d" (List.length rows))
;;

let test_event_queue_pending_rows_carry_operator_visible_fields () =
  with_workspace
  @@ fun config ->
  let keeper_name = "waiting-inventory-kinds" in
  ensure_keeper config keeper_name;
  let message =
    { (stimulus ~post_id:"workspace-message:wmsg-1" ~arrived_at:100.0
         (Keeper_event_queue.Workspace_message
            ({ wmsg_request_id = "wmsg-1"; wmsg_from = "alpha" }
             : Keeper_event_queue.workspace_message)))
      with urgency = Keeper_event_queue.Immediate
    }
  in
  let cancelled =
    stimulus ~post_id:"task-cancelled:T-1" ~arrived_at:101.0
      (Keeper_event_queue.Task_cancelled
         ({ tc_task_id = "T-1"; tc_cancelled_by = "alpha"; tc_reason = None }
          : Keeper_event_queue.task_cancellation))
  in
  let rejected =
    stimulus ~post_id:"completion-authority-rejected:T-2" ~arrived_at:102.0
      (Keeper_event_queue.Completion_authority_rejected
         ({ car_task_id = "T-2"
          ; car_verification_id = "verification-2"
          ; car_reason = "evidence lacks a test run"
          ; car_authority = Masc_domain.System_llm_agent { agent_run_id = "run-2" }
          }
          : Keeper_event_queue.completion_authority_rejection))
  in
  let approved =
    stimulus ~post_id:"task-outcome:T-3" ~arrived_at:103.0
      (Keeper_event_queue.Task_outcome
         ({ to_task_id = "T-3"
          ; to_producer = "polisher"
          ; to_verification_id = "verification-3"
          ; to_authority = Masc_domain.System_llm_agent { agent_run_id = "run-3" }
          }
          : Keeper_event_queue.task_outcome))
  in
  let sensitive_content = "private-board-content-must-not-cross-inventory" in
  let board =
    stimulus ~post_id:"board-post-sensitive" ~arrived_at:103.0
      (Keeper_event_queue.Board_signal
         ({ kind = Keeper_event_queue.Post_created
          ; author = "operator"
          ; title = "private title"
          ; content = sensitive_content
          ; hearth = None
          ; updated_at = None
          ; audience = Keeper_event_queue.Audience_targets [keeper_name]
          }
          : Keeper_event_queue.board_stimulus))
  in
  Keeper_event_queue_persistence.persist
    ~base_path:config.Workspace_utils_backend_setup.base_path
    ~keeper_name
    (queue_of_list [ message; cancelled; rejected; approved; board ]);
  let json =
    Server_keeper_waiting_inventory.dashboard_json_for_keeper config ~keeper_name
  in
  let keeper =
    match find_keeper json keeper_name with
    | Some keeper -> keeper
    | None -> fail "keeper row missing"
  in
  let row_of post_id =
    U.(keeper |> member "waiting_on" |> to_list)
    |> List.find_opt (fun row ->
      U.(row |> member "detail" |> member "post_id") = `String post_id)
    |> function
    | Some row -> row
    | None -> failf "queue row missing for %s" post_id
  in
  let detail_of post_id = U.member "detail" (row_of post_id) in
  let what_of post_id = json_string_member "what" (row_of post_id) in
  check string "workspace message sentence names the sender and urgency"
    "alpha가 보낸 메시지 (즉시)"
    (what_of message.Keeper_event_queue.post_id);
  check string "cancellation sentence names the canceller and task"
    "alpha가 작업 T-1 취소"
    (what_of cancelled.Keeper_event_queue.post_id);
  check string "rejection sentence names the task"
    "작업 T-2 완료 증거 거절됨"
    (what_of rejected.Keeper_event_queue.post_id);
  check string "approval sentence names the task and verification"
    "작업 T-3 증거 승인됨 (verification-3)"
    (what_of approved.Keeper_event_queue.post_id);
  let board_row = U.(keeper |> member "waiting_on" |> to_list)
    |> List.find (fun row -> U.member "waiting_on" row = `String "board_signal") in
  check string "public Board sentence carries no author"
    "Board 알림 대기" (json_string_member "what" board_row);
  let message_detail = detail_of message.Keeper_event_queue.post_id in
  check string "workspace message sender" "alpha"
    (json_string_member "message_from" message_detail);
  check string "workspace message request id" "wmsg-1"
    (json_string_member "message_request_id" message_detail);
  let cancelled_detail = detail_of cancelled.Keeper_event_queue.post_id in
  check string "cancelled task id" "T-1"
    (json_string_member "cancelled_task_id" cancelled_detail);
  check string "cancelled by" "alpha" (json_string_member "cancelled_by" cancelled_detail);
  check bool "absent cancellation reason stays absent" true
    (U.member "cancelled_reason" cancelled_detail = `Null);
  let rejected_detail = detail_of rejected.Keeper_event_queue.post_id in
  check string "rejection reason" "evidence lacks a test run"
    (json_string_member "rejection_reason" rejected_detail);
  check string "rejection task id" "T-2"
    (json_string_member "rejection_task_id" rejected_detail);
  check bool "rejection row does not serialize the authority payload" true
    (U.member "car_authority" rejected_detail = `Null);
  let approved_detail = detail_of approved.Keeper_event_queue.post_id in
  check string "approval task id" "T-3"
    (json_string_member "outcome_task_id" approved_detail);
  check string "approval verification id" "verification-3"
    (json_string_member "outcome_verification_id" approved_detail);
  check bool "approval row does not serialize the authority payload" true
    (U.member "to_authority" approved_detail = `Null);
  let board_detail = U.member "detail" board_row in
  check string "public Board control address is opaque"
    (Keeper_event_queue_state.source_snapshot_ref board)
    (json_string_member "source_ref" board_detail);
  check bool "public Board detail carries no post identifier" true
    (U.member "post_id" board_detail = `Null);
  check bool "board post content does not cross the inventory" false
    (String_util.contains_substring (Yojson.Safe.to_string json) sensitive_content)
;;

let test_keeper_scoped_projection_excludes_other_keepers () =
  with_workspace
  @@ fun config ->
  let requested_keeper = "waiting-inventory-requested" in
  let other_keeper = "waiting-inventory-other" in
  ensure_keeper config requested_keeper;
  ensure_keeper config other_keeper;
  List.iter
    (fun keeper_name ->
       Keeper_event_queue_persistence.persist
         ~base_path:config.Workspace_utils_backend_setup.base_path
         ~keeper_name
         (queue_of_list
            [ stimulus
                ~post_id:("pending-" ^ keeper_name)
                ~arrived_at:100.0
                Keeper_event_queue.Bootstrap
            ]))
    [ requested_keeper; other_keeper ];
  let json =
    Server_keeper_waiting_inventory.dashboard_json_for_keeper
      config
      ~keeper_name:requested_keeper
  in
  check int "one scoped keeper" 1 (json_int_member "keeper_count" json);
  check int "one scoped row" 1 (json_int_member "row_count" json);
  check bool "requested keeper present" true
    (Option.is_some (find_keeper json requested_keeper));
  check bool "other keeper absent" true
    (Option.is_none (find_keeper json other_keeper))
;;

let shutdown_operation_fixture config keeper_name operation_id phase =
  let trace_id = (keeper_meta_exn config keeper_name).runtime.trace_id in
  { Keeper_shutdown_types.schema_version = Keeper_shutdown_types.schema_version
  ; revision = 1
  ; operation_id
  ; keeper_name
  ; lane_ownership = Dormant_meta
  ; trace_id
  ; actor = "test"
  ; cleanup_intent = { reason = Operator_stop_retain_meta; remove_session = false }
  ; turn_disposition = No_inflight_turn
  ; expected_backlog_version = 0
  ; owned_task_ids = []
  ; join_evidence = None
  ; phase
  ; created_at = Masc_domain.now_iso ()
  ; updated_at = Masc_domain.now_iso ()
  }
;;

let persist_shutdown_exn config operation =
  match Keeper_shutdown_store.persist_new ~config operation with
  | Ok () -> ()
  | Error error -> fail (Keeper_shutdown_store.error_to_string error)
;;

let test_owner_shutdown_row_is_deferred () =
  with_workspace
  @@ fun config ->
  let keeper_name = "admission-shutdown-keeper" in
  ensure_keeper config keeper_name;
  Fun.protect
    ~finally:(fun () -> ())
    (fun () ->
      let base_path = config.Workspace_utils_backend_setup.base_path in
      let operation_id = Keeper_shutdown_types.Operation_id.generate () in
      persist_shutdown_exn config
        (shutdown_operation_fixture config keeper_name operation_id Joined_idle);
      (match
         Keeper_owner_registry.begin_shutdown
           ~base_path
           ~keeper_name
           ~operation_id
       with
       | Ok (Masc.Keeper_owner.Shutdown_reserved reservation) ->
         check bool "shutdown reservation is idle" true
           (Option.is_none reservation.in_flight)
       | Ok (Masc.Keeper_owner.Shutdown_already_reserved _) ->
         fail "fresh keeper unexpectedly had a shutdown reservation"
       | Error error ->
         fail (Keeper_owner_registry.command_error_to_string error));
      let json = Server_keeper_waiting_inventory.dashboard_json config in
      check_metric_float "Owner shutdown metric"
        Otel_metric_store.metric_keeper_waiting_count
        ~labels:[ "scope", "keeper"; "source", "owner_shutdown" ]
        1.0;
      check_metric_float "deferred keeper metric"
        Otel_metric_store.metric_keeper_waiting_keeper_count
        ~labels:[ "state", "deferred" ]
        1.0;
      check int "shutdown keeper is counted" 1
        (json_int_member "waiting_keeper_count" json);
      check int "shutdown contributes one row" 1 (json_int_member "row_count" json);
      (match find_keeper json keeper_name with
       | None -> fail "shutdown keeper row missing"
       | Some keeper ->
         check string "shutdown keeper is deferred" "deferred"
           (json_string_member "state" keeper);
         check (list string) "the state names what defers the Keeper"
           [ "owner_shutdown" ] (json_string_list_member "state_sources" keeper);
         check int "shutdown source count" 1
           U.(keeper |> member "sources" |> member "owner_shutdown" |> to_int);
         (match U.(keeper |> member "waiting_on" |> to_list) with
          | [ row ] ->
            check string "shutdown row source" "owner_shutdown"
              (json_string_member "source" row);
            check string "shutdown row waiting_on" "shutdown"
              (json_string_member "waiting_on" row);
            check string "shutdown row wake producer" "keeper_owner_actor"
              (json_string_member "wake_producer" row);
            check string "shutdown waits for its active worker" "wait_for_keeper_shutdown"
              (json_string_member "next_action" row);
            check string "shutdown operation is correlated"
              (Keeper_shutdown_types.Operation_id.to_string operation_id)
              U.(
                row |> member "detail" |> member "shutdown_operation_id"
                |> to_string);
            check bool "admission fence is explicit" true
              U.(row |> member "detail" |> member "admission_fenced" |> to_bool);
            check bool "shutdown has no in-flight turn" true
              U.(row |> member "detail" |> member "in_flight" = `Null)
          | rows -> failf "expected one shutdown row, got %d" (List.length rows)));
      (match
         Keeper_owner_registry.rollback_shutdown
           ~base_path
           ~keeper_name
           ~operation_id
       with
       | Ok Masc.Keeper_owner.Shutdown_rolled_back -> ()
       | Ok Masc.Keeper_owner.Shutdown_not_reserved
       | Ok (Masc.Keeper_owner.Shutdown_reserved_by_other _) ->
         fail "owned shutdown reservation did not roll back"
       | Error error ->
         fail (Keeper_owner_registry.command_error_to_string error));
      let reopened = Server_keeper_waiting_inventory.dashboard_json config in
      match find_keeper reopened keeper_name with
      | None -> fail "reopened keeper row missing"
      | Some keeper ->
        check string "rollback returns keeper to idle" "idle"
          (json_string_member "state" keeper);
        check int "rollback removes shutdown row" 0
          (json_int_member "waiting_count" keeper))
;;

let with_shutdown_fence config keeper_name operation_id f =
  let base_path = config.Masc.Workspace.base_path in
  (match Keeper_owner_registry.begin_shutdown ~base_path ~keeper_name ~operation_id with
   | Ok (Masc.Keeper_owner.Shutdown_reserved _) -> ()
   | Ok (Masc.Keeper_owner.Shutdown_already_reserved _) -> fail "unexpected existing fence"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
  Fun.protect
    ~finally:(fun () ->
      match Keeper_owner_registry.rollback_shutdown ~base_path ~keeper_name ~operation_id with
      | Ok Masc.Keeper_owner.Shutdown_rolled_back -> ()
      | Ok Masc.Keeper_owner.Shutdown_not_reserved
      | Ok (Masc.Keeper_owner.Shutdown_reserved_by_other _) -> fail "shutdown fence changed"
      | Error error -> fail (Keeper_owner_registry.command_error_to_string error))
    f
;;

let test_shutdown_next_action_follows_durable_operation () =
  with_workspace @@ fun config ->
  let open Keeper_shutdown_types in
  let keeper_name = "shutdown-guidance" in
  ensure_keeper config keeper_name;
  let cleanup =
    { settled_task_ids = []; pending_confirms_removed = 0
    ; meta_snapshot_digest = Masc.Keeper_meta_json.Snapshot_digest.of_meta
        (keeper_meta_exn config keeper_name) }
  in
  let finalization completion =
    { cleanup; meta_removed = true; session_removed = false
    ; registry_unregistered = true; completion }
  in
  let active_turn =
    { lane = Some Autonomous; admitted_at = Some 1.; observed_turn_id = None
    ; observation_started_at = None }
  in
  let cases =
    [ Prepared, Operator_stop_retain_meta, "wait_for_keeper_shutdown"
    ; Joining_lanes, Operator_stop_retain_meta, "wait_for_keeper_shutdown"
    ; Cleanup_ready cleanup, Operator_stop_retain_meta, "wait_for_keeper_shutdown"
    ; Blocked { stage = Task_settlement; detail = "recorded settlement failure" },
      Operator_stop_retain_meta, "inspect_blocked_keeper_shutdown"
    ; Reconciliation_required active_turn, Operator_stop_retain_meta,
      "inspect_keeper_shutdown_reconciliation"
    ; Finalized (finalization (Completion_pending Dashboard_keeper_purged)),
      Dashboard_keeper_purge { requested_name = keeper_name }, "retry_keeper_shutdown_completion"
    ; Finalized (finalization (Completion_delivery_failed
        { action = Dashboard_keeper_purged; detail = "delivery failed" })),
      Dashboard_keeper_purge { requested_name = keeper_name }, "retry_keeper_shutdown_completion"
    ; Finalized (finalization (Completion_pending Supervisor_cleaned)),
      Supervisor_cleanup, "inspect_keeper_shutdown_completion"
    ; Finalized (finalization (Completion_delivered Supervisor_cleaned)),
      Supervisor_cleanup, "inspect_keeper_shutdown_fence"
    ; Superseded (Operator_metadata_update { actor = "test" }),
      Operator_stop_retain_meta, "inspect_keeper_shutdown_fence"
    ]
  in
  List.iter (fun (phase, reason, expected_action) ->
    let operation_id = Operation_id.generate () in
    let operation = shutdown_operation_fixture config keeper_name operation_id phase in
    let operation = { operation with cleanup_intent = { operation.cleanup_intent with reason } } in
    persist_shutdown_exn config operation;
    with_shutdown_fence config keeper_name operation_id (fun () ->
      let json = Server_keeper_waiting_inventory.dashboard_json config in
      let keeper = match find_keeper json keeper_name with
        | Some keeper -> keeper | None -> fail "keeper missing" in
      check string "fence remains deferred" "deferred" (json_string_member "state" keeper);
      match U.(keeper |> member "waiting_on" |> to_list) with
      | [ row ] ->
        check string "action matches recorded operation capability" expected_action
          (json_string_member "next_action" row);
        let detail = U.member "detail" row in
        check string "phase is the persisted observation" (phase_to_string phase)
          (json_string_member "shutdown_phase" detail);
        check int "revision is the persisted observation" operation.revision
          (json_int_member "shutdown_revision" detail);
        (match phase with
         | Blocked failure ->
           check string "blocked stage remains available" (failure_stage_to_string failure.stage)
             (json_string_member "failure_stage" detail);
           check string "blocked evidence remains available" failure.detail
             (json_string_member "failure_detail" detail)
         | Prepared | Joining_lanes | Joined_idle | Finalizing_tasks _ | Cleanup_ready _
         | Reconciliation_required _ | Finalized _ | Owner_absent _
         | Operator_absence_acknowledged _ | Superseded _ -> ())
      | rows -> failf "expected one shutdown row, got %d" (List.length rows))) cases
;;

let test_unreadable_shutdown_keeps_fence_and_read_error () =
  with_workspace @@ fun config ->
  let keeper_name = "shutdown-unreadable" in
  ensure_keeper config keeper_name;
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  with_shutdown_fence config keeper_name operation_id (fun () ->
    let observe () =
      let json = Server_keeper_waiting_inventory.dashboard_json config in
      let keeper = match find_keeper json keeper_name with
        | Some keeper -> keeper | None -> fail "keeper missing" in
      check string "unreadable record does not release the fence" "deferred"
        (json_string_member "state" keeper);
      let rows = U.(keeper |> member "waiting_on" |> to_list) in
      check int "fence and storage failure remain separate" 2 (List.length rows);
      let fence = List.find (fun row -> json_string_member "source" row = "owner_shutdown") rows in
      check string "unknown phase cannot suggest finalization" "inspect_keeper_shutdown_record"
        (json_string_member "next_action" fence);
      check bool "unknown phase is not defaulted" true
        U.(fence |> member "detail" |> member "shutdown_phase" = `Null);
      let health = Server_keeper_waiting_inventory.health_json config in
      check string "storage failure remains unavailable" "unavailable"
        (json_string_member "status" health);
      check bool "storage failure preserves unknown completeness" false
        (json_bool_member "counts_known" health);
      check bool "storage failure remains actionable" true
        (json_bool_member "operator_action_required" health);
      check int "one storage failure is observed" 1 (json_int_member "read_error_count" health)
    in
    observe ();
    let path = match Keeper_shutdown_store.path ~config ~keeper_name operation_id with
      | Ok path -> path | Error error -> fail (Keeper_shutdown_store.error_to_string error) in
    Fs_compat.mkdir_p (Filename.dirname path);
    (match Fs_compat.save_file_atomic path "not-json" with
     | Ok () -> () | Error detail -> fail detail);
    observe ())
;;

let test_keeper_owned_schedule_waiting_rows_are_lane_scoped () =
  with_workspace
  @@ fun config ->
  let keeper_name = "scheduled-keeper" in
  ensure_keeper config keeper_name;
  ignore
    (create_schedule_exn
       config
       ~schedule_id:"sched-owned"
       ~scheduled_by:(automated keeper_name)
      : Schedule_domain.schedule_request);
  ignore
    (create_schedule_exn
       config
       ~schedule_id:"sched-global"
       ~scheduled_by:(automated "unknown-scheduler")
      : Schedule_domain.schedule_request);
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check_metric_float "keeper schedule metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "keeper"; "source", "schedule_waiting" ]
    1.0;
  check_metric_float "global schedule metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "global"; "source", "schedule_waiting" ]
    1.0;
  check int "one keeper row" 1 (json_int_member "row_count" json);
  check int "one global row" 1 (json_int_member "global_row_count" json);
  (match find_keeper json keeper_name with
   | None -> fail "keeper row missing"
   | Some keeper ->
     check string "keeper state" "waiting" (json_string_member "state" keeper);
     check int "keeper waiting count" 1 (json_int_member "waiting_count" keeper);
     check int "keeper schedule source" 1
       U.(keeper |> member "sources" |> member "schedule_waiting" |> to_int);
     (match U.(keeper |> member "waiting_on" |> to_list) with
      | [ row ] ->
        check string "keeper schedule source row" "schedule_waiting"
          (json_string_member "source" row);
        check string "keeper schedule wake producer" "schedule_runner"
          (json_string_member "wake_producer" row);
        check string "keeper next action" "wait_until_due"
          (json_string_member "next_action" row);
        check string "keeper schedule id" "sched-owned"
          U.(row |> member "detail" |> member "schedule_id" |> to_string);
        check string "schedule sentence names the schedule" "예약 실행 · sched-owned"
          (json_string_member "what" row)
      | rows -> failf "expected one keeper schedule row, got %d" (List.length rows)));
  match U.(json |> member "global_waiting_on" |> to_list) with
  | [ row ] ->
    check string "global schedule source row" "schedule_waiting"
      (json_string_member "source" row);
    check string "global schedule wake producer" "schedule_runner"
      (json_string_member "wake_producer" row);
    check string "global schedule id" "sched-global"
      U.(row |> member "detail" |> member "schedule_id" |> to_string)
  | rows -> failf "expected one global schedule row, got %d" (List.length rows)
;;

let test_live_turn_keeper_is_busy_without_waiting_rows () =
  with_workspace
  @@ fun config ->
  let keeper_name = "busy-keeper" in
  ensure_keeper config keeper_name;
  let meta = keeper_meta_exn config keeper_name in
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.clear ())
    (fun () ->
      ignore
        (Keeper_registry.For_testing.register
           ~base_path:config.Workspace_utils_backend_setup.base_path
           keeper_name
           meta);
      Keeper_registry.mark_turn_started ~observation_token:(Masc.Keeper_turn_observation_token.fresh ())
        ~base_path:config.Workspace_utils_backend_setup.base_path
        ~wake:Keeper_registry.Proactive_tick
        keeper_name;
      let json = Server_keeper_waiting_inventory.dashboard_json config in
      check_metric_float "busy keeper metric"
        Otel_metric_store.metric_keeper_waiting_keeper_count
        ~labels:[ "state", "busy" ]
        1.0;
      check int "busy keeper is counted as non-idle" 1
        (json_int_member "waiting_keeper_count" json);
      check int "busy state does not invent waiting rows" 0
        (json_int_member "row_count" json);
      match find_keeper json keeper_name with
      | None -> fail "keeper row missing"
      | Some keeper ->
        check string "state" "busy" (json_string_member "state" keeper);
        check int "waiting count" 0 (json_int_member "waiting_count" keeper))
;;

let save_text path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  match Fs_compat.save_file_atomic path text with
  | Ok () -> ()
  | Error err -> fail ("save_file_atomic failed: " ^ err)
;;

(* RFC-0484 §3.1: a running Keeper whose every candidate has spent its quota
   window. The two providers carry no credential, so each has its own quota
   scope ([Runtime_quota_window.scope_of_credential] falls back to the
   provider id) and one can be spent without the other. *)
let quota_runtime_toml =
  {|
[runtime]
default = "primary.test_model"

[runtime.lanes.quota-lane]
candidates = [ "primary.test_model", "fallback.test_model" ]

[runtime.assignments]
"quota-keeper" = "quota-lane"

[providers.primary]
display-name = "Primary Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.fallback]
display-name = "Fallback Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:2"

[models.test_model]
api-name = "test-model"
max-context = 200000
tools-support = true
streaming = true

[primary.test_model]
is-default = true
max-concurrent = 1

[fallback.test_model]
max-concurrent = 1
|}
;;

let with_quota_runtime f =
  let snapshot = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "keeper_waiting_inventory_runtime_" ".toml" in
  Runtime_quota_window.reset_for_testing ();
  Fun.protect
    ~finally:(fun () ->
      Runtime_quota_window.reset_for_testing ();
      Runtime.For_testing.restore snapshot;
      try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       save_text path quota_runtime_toml;
       match Runtime.init_default ~config_path:path with
       | Ok () -> f ()
       | Error e -> fail ("Runtime.init_default failed: " ^ e))
;;

let spend_quota runtime_id ~resets_at =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> fail ("runtime not loaded: " ^ runtime_id)
  | Some runtime ->
    Runtime_quota_window.note_exhausted
      ~scope:(Runtime_instance.quota_scope_of_runtime runtime)
      ~resets_at
;;

let with_running_keeper config keeper_name f =
  ensure_keeper config keeper_name;
  let meta = keeper_meta_exn config keeper_name in
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.clear ())
    (fun () ->
       ignore
         (Keeper_registry.For_testing.register
            ~base_path:config.Workspace_utils_backend_setup.base_path
            keeper_name
            meta);
       f ())
;;

let quota_spent_rows json keeper_name =
  match find_keeper json keeper_name with
  | None -> fail "keeper row missing"
  | Some keeper ->
    U.(keeper |> member "waiting_on" |> to_list)
    |> List.filter (fun row ->
      String.equal "runtime_quota_spent" (json_string_member "source" row))
;;

let health_action_reasons health =
  U.(health |> member "operator_action_reasons" |> to_list |> filter_string)
;;

let test_every_candidate_spent_waits_for_the_earliest_reset () =
  with_workspace
  @@ fun config ->
  with_quota_runtime
  @@ fun () ->
  let keeper_name = "quota-keeper" in
  with_running_keeper config keeper_name
  @@ fun () ->
  let now = Unix.gettimeofday () in
  let earlier = now +. 3600. in
  let later = now +. 7200. in
  spend_quota "primary.test_model" ~resets_at:later;
  spend_quota "fallback.test_model" ~resets_at:earlier;
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  (match quota_spent_rows json keeper_name with
   | [ row ] ->
     check string "the row names the route" "quota-lane" (json_string_member "waiting_on" row);
     check (float 0.001) "the Keeper can dispatch again at the earliest stated reset" earlier
       U.(row |> member "due_at" |> to_number);
     check string "the operator can move it to a route with quota left"
       "assign_a_route_with_open_quota" (json_string_member "next_action" row);
     check string "its own supervisor wakes it at the reset" "keeper_supervisor"
       (json_string_member "wake_producer" row);
     check int "both spent candidates are listed" 2
       (List.length U.(row |> member "detail" |> member "candidates" |> to_list))
   | rows -> failf "expected one quota spent row, got %d" (List.length rows));
  let health = Server_keeper_waiting_inventory.health_json config in
  check string "the fleet is degraded while a Keeper cannot dispatch" "degraded"
    (json_string_member "status" health);
  check bool "the operator is asked to act" true
    (json_bool_member "operator_action_required" health);
  check bool "the reason counts the waiting Keepers" true
    (List.mem "runtime_quota_spent=1" (health_action_reasons health))
;;

let test_quota_spent_needs_every_candidate_and_a_running_keeper () =
  with_workspace
  @@ fun config ->
  with_quota_runtime
  @@ fun () ->
  let keeper_name = "quota-keeper" in
  let now = Unix.gettimeofday () in
  with_running_keeper config keeper_name (fun () ->
    spend_quota "primary.test_model" ~resets_at:(now +. 3600.);
    let json = Server_keeper_waiting_inventory.dashboard_json config in
    check int "one open candidate is a route the Keeper still uses" 0
      (List.length (quota_spent_rows json keeper_name));
    check bool "and asks nothing of the operator" false
      (List.mem "runtime_quota_spent=1"
         (health_action_reasons (Server_keeper_waiting_inventory.health_json config))));
  spend_quota "fallback.test_model" ~resets_at:(now +. 3600.);
  (* [with_running_keeper] cleared the registry on the way out: the Keeper is
     configured and every candidate is spent, but the server is not running it. *)
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check int "a Keeper the server does not run does not dispatch" 0
    (List.length (quota_spent_rows json keeper_name))
;;

let pending_confirm_fixture ()
      : Operator_pending_confirm.pending_confirm
  =
  { confirm_token = "confirm-broadcast-1"
  ; trace_id = "trace-broadcast-1"
  ; actor = "operator"
  ; action_type = "broadcast"
  ; target_type = "workspace"
  ; target_id = None
  ; payload = `Assoc [ "message", `String "maintenance notice" ]
  ; delegated_tool = "masc_broadcast"
  ; created_at = "2026-07-07T00:00:00Z"
  ; expires_at = None
  }
;;

let write_pending_confirms_exn config entries =
  match Operator_pending_confirm.write_pending_confirms config entries with
  | Ok () -> ()
  | Error err -> fail ("write pending confirms failed: " ^ err)
;;

let test_scoped_confirmations_keep_target_identity () =
  with_workspace @@ fun config ->
  let requested = "confirm-requested" and other = "confirm-other" in
  ensure_keeper config requested;
  ensure_keeper config other;
  let global = pending_confirm_fixture () in
  let targeted target token =
    { global with
      Operator_pending_confirm.action_type = "keeper_message";
      Operator_pending_confirm.target_type = "keeper";
      Operator_pending_confirm.target_id = Some target;
      Operator_pending_confirm.delegated_tool = "masc_keeper_delegate";
      confirm_token = token } in
  write_pending_confirms_exn config
    [global; targeted requested "confirm-a"; targeted other "confirm-b";
     targeted "not-registered" "confirm-missing"];
  let json = Server_keeper_waiting_inventory.dashboard_json_for_keeper config ~keeper_name:requested in
  let tokens rows = List.map (fun row -> U.(row |> member "detail" |> member "confirm_token" |> to_string)) rows in
  check (list string) "scoped global rows contain only workspace confirmation"
    [global.confirm_token] (tokens U.(json |> member "global_waiting_on" |> to_list));
  check int "global confirmation count comes from those exact rows" 1
    (json_int_member "global_pending_confirm_count" json);
  let keeper = match find_keeper json requested with Some row -> row | None -> fail "missing requested keeper" in
  check (list string) "only the requested keeper confirmation is local"
    ["confirm-a"] (tokens U.(keeper |> member "waiting_on" |> to_list));
  let fleet = Server_keeper_waiting_inventory.dashboard_json config in
  check (list string) "fleet still exposes an unresolved target for diagnosis"
    [global.confirm_token; "confirm-missing"]
    (tokens U.(fleet |> member "global_waiting_on" |> to_list));
  save_text (Operator_pending_confirm.pending_confirms_path config) "{broken";
  let failed = Server_keeper_waiting_inventory.dashboard_json_for_keeper config ~keeper_name:requested in
  check bool "scoped pending confirmation read failure is not zero certainty" false
    (json_bool_member "global_pending_confirm_count_known" failed);
  check (list string) "scoped view retains authoritative read failure" ["read_error"]
    (U.(failed |> member "global_waiting_on" |> to_list) |> List.map (json_string_member "source"))
;;

let test_scoped_schedules_keep_participant_identity () =
  with_workspace @@ fun config ->
  let requested = "schedule-requested" and other = "schedule-other" in
  ensure_keeper config requested;
  ensure_keeper config other;
  List.iter (fun (schedule_id, scheduled_by) ->
    ignore (create_schedule_exn config ~schedule_id ~scheduled_by : Schedule_domain.schedule_request))
    ["sched-a", automated requested; "sched-b", automated other;
     "sched-unknown", automated "unknown-actor"; "sched-human", human "operator";
     "sched-system", {Schedule_domain.id="system"; kind=System; display_name=None}];
  let wake_payload target =
    `Assoc ["kind", `String "masc.keeper_wake";
      "body", `Assoc ["keeper_name", `String target; "message", `String "check work"]] in
  let system : Schedule_domain.actor = {id="system"; kind=System; display_name=None} in
  List.iter (fun (schedule_id, scheduled_by, target) ->
    ignore (create_schedule_exn ~payload:(wake_payload target) config ~schedule_id ~scheduled_by
      : Schedule_domain.schedule_request))
    ["wake-b-a", automated other, requested;
     "wake-a-b", automated requested, other;
     "wake-a-a", automated requested, requested;
     "wake-human-a", human "operator", requested;
     "wake-human-b", human "operator", other;
     "wake-system-a", system, requested;
     "wake-system-b", system, other;
     "wake-unknown-a", automated "unknown-actor", requested];
  let ids rows = rows |> List.map (fun row -> U.(row |> member "detail" |> member "schedule_id" |> to_string))
      |> List.sort String.compare in
  let json = Server_keeper_waiting_inventory.dashboard_json_for_keeper config ~keeper_name:requested in
  check (list string) "unrelated workspace reservations are absent from the Keeper view"
    [] (ids U.(json |> member "global_waiting_on" |> to_list));
  let keeper = match find_keeper json requested with Some row -> row | None -> fail "missing keeper" in
  check (list string) "creator and wake target both see the schedule locally"
    ["sched-a"; "wake-a-a"; "wake-a-b"; "wake-b-a"; "wake-human-a";
     "wake-system-a"; "wake-unknown-a"]
    (ids U.(keeper |> member "waiting_on" |> to_list));
  check int "self-wake is counted once and unrelated targets are excluded" 7
    (json_int_member "total_row_count" json);
  let other_json = Server_keeper_waiting_inventory.dashboard_json_for_keeper config ~keeper_name:other in
  let other_keeper = match find_keeper other_json other with Some row -> row | None -> fail "missing other keeper" in
  check (list string) "the other participant sees both directions and only its own wake targets"
    ["sched-b"; "wake-a-b"; "wake-b-a"; "wake-human-b"; "wake-system-b"]
    (ids U.(other_keeper |> member "waiting_on" |> to_list));
  let fleet = Server_keeper_waiting_inventory.dashboard_json config in
  check (list string) "fleet keeps unknown-actor reservations visible"
    ["sched-human";"sched-system";"sched-unknown"]
    (ids U.(fleet |> member "global_waiting_on" |> to_list));
  check int "fleet counts each reservation once, including cross-Keeper wakes" 13
    (json_int_member "total_row_count" fleet);
  let fleet_rows = U.(fleet |> member "keepers" |> to_list)
    |> List.concat_map (fun row -> U.(row |> member "waiting_on" |> to_list)) in
  let cross_wake = List.find (fun row ->
    U.(row |> member "detail" |> member "schedule_id" |> to_string) = "wake-b-a") fleet_rows in
  check (list string) "fleet row retains both participants"
    [other; requested]
    U.(cross_wake |> member "detail" |> member "keeper_participants" |> to_list |> List.map to_string);
  let masc_dir = Workspace_utils.masc_dir config in
  (* RFC-0234: a corrupt primary with a parseable .last-good mirror loads from
     the mirror on purpose (Loaded + warning, not Corrupt). To pin the
     read_error surface both copies must be unreadable. *)
  save_text (Filename.concat masc_dir "schedules.json") "{broken";
  save_text (Filename.concat masc_dir "schedules.json.last-good") "{broken too";
  let failed = Server_keeper_waiting_inventory.dashboard_json_for_keeper config ~keeper_name:requested in
  check (list string) "scoped schedule read failure stays visible" ["read_error"]
    (U.(failed |> member "global_waiting_on" |> to_list) |> List.map (json_string_member "source"))
;;

let test_nonlive_keeper_has_no_current_execution () =
  with_workspace @@ fun config ->
  let keeper_name = "retained-turn" in
  ensure_keeper config keeper_name;
  let meta = keeper_meta_exn config keeper_name in
  let base_path = config.Workspace_utils_backend_setup.base_path in
  Keeper_registry.For_testing.clear ();
  Fun.protect ~finally:(fun () -> Keeper_registry.For_testing.clear ()) @@ fun () ->
  ignore (Keeper_registry.For_testing.register ~base_path keeper_name meta);
  Keeper_registry.mark_turn_started
    ~observation_token:(Masc.Keeper_turn_observation_token.fresh ())
    ~base_path ~wake:Keeper_registry.Chat_request keeper_name;
  List.iter (fun phase ->
    (match Keeper_registry.update_entry ~base_path keeper_name (fun entry -> {entry with phase}) with
     | Ok () -> () | Error _ -> fail "could not set nonlive phase");
    let json = Server_keeper_waiting_inventory.dashboard_json_for_keeper config ~keeper_name in
    check int "nonlive observation is not counted busy" 0 (json_int_member "waiting_keeper_count" json);
    let keeper = match find_keeper json keeper_name with Some row -> row | None -> fail "missing keeper" in
    check string "no pending rows and no active turn is idle" "idle" (json_string_member "state" keeper);
    check bool "queue current execution is absent" true U.(member "current_execution" keeper = `Null))
    Keeper_state_machine.[Offline; Stopped; Crashed; Restarting]
;;

let test_corrupt_schedule_ledger_is_read_error () =
  with_workspace
  @@ fun config ->
  save_text
    (Filename.concat (Workspace_utils.masc_dir config) "schedules.json")
    "{not-json";
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check_metric_float "global read error metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "global"; "source", "read_error" ]
    1.0;
  check int "global read error row" 1 (json_int_member "global_row_count" json);
  match U.(json |> member "global_waiting_on" |> to_list) with
  | [ row ] ->
    check string "source" "read_error" (json_string_member "source" row);
    check string "waiting_on" "schedule_store" (json_string_member "waiting_on" row);
    check string "read error sentence names the store" "대기 기록 읽기 실패 · schedule_store"
      (json_string_member "what" row);
    check string "wake producer" "read_model_reader"
      (json_string_member "wake_producer" row);
    check string "next action" "repair_schedule_ledger"
      (json_string_member "next_action" row)
  | [] -> fail "expected one global waiting row, got none"
  | _first :: _second :: _rest -> fail "expected one global waiting row, got multiple"
;;

let test_keeper_name_discovery_failure_is_read_error () =
  with_workspace
  @@ fun config ->
  let keeper_dir = Keeper_types_profile.keeper_dir config in
  rm_rf keeper_dir;
  save_text keeper_dir "not-a-directory";
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check_metric_float "global keeper-name read error metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "global"; "source", "read_error" ]
    1.0;
  check bool "keeper count unknown" false
    (json_bool_member "keeper_count_known" json);
  check int "keeper count stays compatibility zero" 0
    (json_int_member "keeper_count" json);
  check int "global read error row" 1 (json_int_member "global_row_count" json);
  match U.(json |> member "global_waiting_on" |> to_list) with
  | [ row ] ->
    check string "source" "read_error" (json_string_member "source" row);
    check string "waiting_on" "keeper_meta_store"
      (json_string_member "waiting_on" row);
    check string "wake producer" "read_model_reader"
      (json_string_member "wake_producer" row);
    check string "next action" "repair_keeper_meta_store"
      (json_string_member "next_action" row)
  | [] -> fail "expected one global waiting row, got none"
  | _first :: _second :: _rest -> fail "expected one global waiting row, got multiple"
;;

let test_corrupt_external_attention_is_read_error () =
  with_workspace
  @@ fun config ->
  let keeper_name = "external-attention-corrupt-keeper" in
  ensure_keeper config keeper_name;
  save_text
    (Keeper_external_attention.attention_path
       ~base_path:config.Workspace_utils_backend_setup.base_path
       ~keeper_name)
    "{not-json\n";
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check_metric_float "keeper external-attention read error metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "keeper"; "source", "read_error" ]
    1.0;
  check_metric_float "keeper read-error state metric"
    Otel_metric_store.metric_keeper_waiting_keeper_count
    ~labels:[ "state", "waiting" ]
    1.0;
  check int "one waiting keeper" 1 (json_int_member "waiting_keeper_count" json);
  check int "one keeper read error row" 1 (json_int_member "row_count" json);
  match find_keeper json keeper_name with
  | None -> fail "keeper row missing"
  | Some keeper ->
    check string "keeper state" "waiting" (json_string_member "state" keeper);
    check int "keeper waiting count" 1 (json_int_member "waiting_count" keeper);
    check int "keeper read_error source" 1
      U.(keeper |> member "sources" |> member "read_error" |> to_int);
    (match U.(keeper |> member "waiting_on" |> to_list) with
     | [ row ] ->
       check string "source" "read_error" (json_string_member "source" row);
       check string "waiting_on" "external_attention_store"
         (json_string_member "waiting_on" row);
       check string "wake producer" "read_model_reader"
         (json_string_member "wake_producer" row);
       check string "next action" "repair_external_attention_store"
         (json_string_member "next_action" row)
     | [] -> fail "expected one keeper waiting row, got none"
     | _first :: _second :: _rest -> fail "expected one keeper waiting row, got multiple")
;;

let test_global_pending_confirm_is_actionable_row () =
  with_workspace
  @@ fun config ->
  ensure_keeper config "known-keeper";
  write_pending_confirms_exn
    config
    [ pending_confirm_fixture () ];
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check_metric_float "global pending-confirm metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "global"; "source", "operator_pending_confirm" ]
    1.0;
  check bool "pending-confirm count known" true
    (json_bool_member "global_pending_confirm_count_known" json);
  check int "global pending-confirm count" 1
    (json_int_member "global_pending_confirm_count" json);
  check int "global pending-confirm row" 1 (json_int_member "global_row_count" json);
  match U.(json |> member "global_waiting_on" |> to_list) with
  | [ row ] ->
    let detail = U.(row |> member "detail") in
    check string "source" "operator_pending_confirm" (json_string_member "source" row);
    check string "waiting_on" "broadcast" (json_string_member "waiting_on" row);
    check string "wake producer" "operator_pending_confirm_store"
      (json_string_member "wake_producer" row);
    check string "next action" "operator_confirm_action"
      (json_string_member "next_action" row);
    check string "confirm token" "confirm-broadcast-1"
      U.(detail |> member "confirm_token" |> to_string);
    check string "trace_id" "trace-broadcast-1"
      U.(detail |> member "trace_id" |> to_string);
    check string "target_type" "workspace"
      U.(detail |> member "target_type" |> to_string);
    check bool "target_id is absent" true U.(detail |> member "target_id" = `Null);
    check string "delegated_tool" "masc_broadcast"
      U.(detail |> member "delegated_tool" |> to_string)
  | rows -> failf "expected one global pending-confirm row, got %d" (List.length rows)
;;

let test_corrupt_pending_confirms_is_read_error () =
  with_workspace
  @@ fun config ->
  save_text (Operator_pending_confirm.pending_confirms_path config) "{not-json";
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check_metric_float "global pending-confirm read error metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "global"; "source", "read_error" ]
    1.0;
  check bool "pending-confirm count unknown" false
    (json_bool_member "global_pending_confirm_count_known" json);
  check int "global pending-confirm count stays compatibility zero" 0
    (json_int_member "global_pending_confirm_count" json);
  check int "global read error row" 1 (json_int_member "global_row_count" json);
  match U.(json |> member "global_waiting_on" |> to_list) with
  | [ row ] ->
    check string "source" "read_error" (json_string_member "source" row);
    check string "waiting_on" "operator_pending_confirm_store"
      (json_string_member "waiting_on" row);
    check string "wake producer" "read_model_reader"
      (json_string_member "wake_producer" row);
    check string "next action" "repair_operator_pending_confirms"
      (json_string_member "next_action" row)
  | [] -> fail "expected one global waiting row, got none"
  | _first :: _second :: _rest -> fail "expected one global waiting row, got multiple"
;;

let test_unavailable_pending_approval_store_is_read_error () =
  with_workspace
  @@ fun config ->
  let error : Masc.Keeper_approval_queue_result.storage_error =
    { path = "keeper_gate_pending.json"
    ; reason = "current snapshot requires runtime reset"
    }
  in
  let json =
    Server_keeper_waiting_inventory.For_testing.dashboard_json_with_pending_reader
      ~read_pending:(fun ~base_path:_ -> Error error)
      config
  in
  check string
    "pending approval state"
    "unavailable"
    U.(json |> member "pending_approval_state" |> member "state" |> to_string);
  check string
    "pending approval recovery"
    "reset_required"
    U.(json |> member "pending_approval_state" |> member "code" |> to_string);
  match U.(json |> member "global_waiting_on" |> to_list) with
  | [ row ] ->
    check string "source" "read_error" (json_string_member "source" row);
    check string
      "waiting_on"
      "keeper_gate_pending_store"
      (json_string_member "waiting_on" row);
    check string
      "next action"
      "reset_runtime_state"
      (json_string_member "next_action" row)
  | rows ->
    failf "expected one pending-store read error row, got %d" (List.length rows)
;;

let test_health_counts_normal_waiting_without_alarm () =
  with_workspace @@ fun config ->
  ignore (create_schedule_exn config ~schedule_id:"health-pending"
    ~scheduled_by:(automated "unknown-scheduler") : Schedule_domain.schedule_request);
  let health = Server_keeper_waiting_inventory.health_json config in
  check string "waiting alone is not a fault" "ok" (json_string_member "status" health);
  check bool "normal waiting needs no intervention" false U.(health |> member "operator_action_required" |> to_bool);
  check bool "readable primary is complete" true U.(health |> member "counts_known" |> to_bool);
  check int "one visible schedule row" 1 (json_int_member "total_row_count" health);
  check string "primary read source" "primary" U.(health |> member "schedule_ledger" |> member "source" |> to_string);
  check int "scheduled count" 1 U.(health |> member "schedule_ledger" |> member "observed_status_counts" |> member "scheduled" |> to_int);
  check int "waiting source matches dashboard" 1 U.(health |> member "observed_source_counts" |> member "schedule_waiting" |> to_int)
;;

let test_health_retains_recovery_observation_without_known_totals () =
  with_workspace @@ fun config ->
  ignore (create_schedule_exn config ~schedule_id:"health-recovery"
    ~scheduled_by:(automated "unknown-scheduler") : Schedule_domain.schedule_request);
  let primary = Filename.concat (Workspace_utils.masc_dir config) "schedules.json" in
  let original_primary = Workspace_core.read_text config primary in
  save_text primary "{private primary /sensitive/path token=secret";
  let check_recovery reason =
    let health = Server_keeper_waiting_inventory.health_json config in
    check string "recovery is visible" "degraded" (json_string_member "status" health);
    check bool "mirror completeness unknown" false U.(health |> member "counts_known" |> to_bool);
    check bool "no authoritative total" true U.(health |> member "total_row_count" = `Null);
    check int "recovery rows remain observed" 1 (json_int_member "observed_row_count" health);
    check int "mirror schedules remain observed" 1 U.(health |> member "schedule_ledger" |> member "observed_schedule_count" |> to_int);
    check bool "no authoritative ledger total" true U.(health |> member "schedule_ledger" |> member "schedule_count" = `Null);
    check (list string) "stable repair reason" [reason] U.(health |> member "status_reasons" |> to_list |> List.map to_string);
    (match Server_keeper_waiting_inventory.keeper_json_by_name config with
     | Error errors ->
       check bool "turns waiting observation names the incomplete primary" true
         (List.exists (fun row -> U.(row |> member "waiting_on" |> to_string) = reason) errors)
     | Ok _ -> fail "recovery mirror must not become a complete waiting observation");
    check bool "health has no private diagnostic" false
      (String_util.contains_substring (Yojson.Safe.to_string health) "sensitive")
  in
  check_recovery "schedule_primary_unusable";
  check string "health does not repair corrupt primary"
    "{private primary /sensitive/path token=secret" (Workspace_core.read_text config primary);
  Workspace_core.delete_path config primary;
  check_recovery "schedule_primary_missing";
  save_text (primary ^ ".last-good") "{unreadable mirror";
  let health = Server_keeper_waiting_inventory.health_json config in
  check string "unreadable is not empty" "unavailable" (json_string_member "status" health);
  check bool "unreadable ledger count unknown" true U.(health |> member "schedule_ledger" |> member "observed_schedule_count" = `Null);
  check bool "unreadable work total unknown" true U.(health |> member "total_row_count" = `Null);
  check int "read failure remains separate from work" 1 (json_int_member "read_error_count" health);
  save_text primary original_primary;
  (match Server_keeper_waiting_inventory.keeper_json_by_name config with
   | Ok _ -> ()
   | Error _ -> fail "restored primary must clear the incomplete waiting observation")
;;

let test_health_partial_source_failure_and_exception_are_not_empty () =
  with_workspace @@ fun config ->
  ignore (create_schedule_exn config ~schedule_id:"health-readable"
    ~scheduled_by:(automated "unknown-scheduler") : Schedule_domain.schedule_request);
  let read_pending ~base_path:_ =
    Error Masc.Keeper_approval_queue_result.{path="/private/secret"; reason="secret-token"}
  in
  let health = Server_keeper_waiting_inventory.For_testing.health_json_with_pending_reader
    ~read_pending config in
  check string "one failed source degrades whole observation" "unavailable" (json_string_member "status" health);
  check int "readable schedule still visible" 1 (json_int_member "observed_row_count" health);
  check bool "partial inventory total unknown" true U.(health |> member "total_row_count" = `Null);
  check bool "raw error omitted" false (String_util.contains_substring (Yojson.Safe.to_string health) "secret");
  let failed = Server_keeper_waiting_inventory.For_testing.health_json_with_pending_reader
    ~read_pending:(fun ~base_path:_ -> raise (Sys_error "/private/secret-token")) config in
  check string "unexpected failure explicit" "error" (json_string_member "status" failed);
  check bool "exception does not become zero" true U.(failed |> member "observed_row_count" = `Null);
  check bool "exception diagnostic omitted" false (String_util.contains_substring (Yojson.Safe.to_string failed) "secret")
;;

let test_health_placeholder_has_unknown_counts () =
  let health = Server_keeper_waiting_inventory.health_placeholder ~status:Health_status.Warming in
  check bool "not observed" false U.(health |> member "counts_known" |> to_bool);
  List.iter (fun key -> check bool (key ^ " is unknown") true U.(health |> member key = `Null))
    ["keeper_count"; "total_row_count"; "observed_row_count"; "observed_source_counts"; "read_error_count"; "observation_error_count"; "schedule_ledger"]
;;

let admit_stimulus config keeper_name stimulus =
  match
    Keeper_event_queue_persistence.enqueue_stimulus_if_absent_result
      ~base_path:config.Workspace_utils_backend_setup.base_path
      ~keeper_name
      stimulus
  with
  | Ok _ -> ()
  | Error err -> fail ("enqueue failed: " ^ err)
;;

let queue_residence_of_keeper json keeper_name =
  match find_keeper json keeper_name with
  | None -> fail ("keeper row missing: " ^ keeper_name)
  | Some keeper -> keeper, U.member "queue_residence" keeper
;;

let test_queue_residence_is_the_admission_time_not_the_source_time () =
  with_workspace
  @@ fun config ->
  let keeper_name = "queue-residence-keeper" in
  ensure_keeper config keeper_name;
  let before = Unix.gettimeofday () in
  admit_stimulus
    config
    keeper_name
    (stimulus ~post_id:"residence-1" ~arrived_at:100.0 Keeper_event_queue.Bootstrap);
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  let keeper, residence = queue_residence_of_keeper json keeper_name in
  check bool "row since stays the source's own arrival time" true
    (Float.equal 100.0 U.(keeper |> member "since" |> to_float));
  check string "residence is observed" "observed" (json_string_member "status" residence);
  let admitted_at = U.(residence |> member "oldest_admitted_at_unix" |> to_float) in
  check bool "residence starts at the durable admission clock" true
    (admitted_at >= before);
  check bool "residence age is not the source age" true
    (U.(residence |> member "oldest_age_seconds" |> to_float) < 100.0)
;;

let test_queue_residence_without_a_recorded_clock_is_unknown () =
  (* The persistence path always stamps an admission clock, so a selection
     without one can only come from an old snapshot or [with_pending]: this
     case lives at the pure projection boundary, not behind [persist]. *)
  let queue =
    queue_of_list
      [ stimulus ~post_id:"residence-2" ~arrived_at:100.0 Keeper_event_queue.Bootstrap ]
  in
  let state =
    Keeper_event_queue_state.with_pending queue Keeper_event_queue_state.empty
  in
  let selections = Keeper_event_queue_state.pending_selections state in
  let residence =
    Keeper_event_queue_fleet_projection.queue_residence_of_selections
      ~now:(Unix.gettimeofday ())
      ~complete:true
      selections
  in
  (match residence with
   | Keeper_event_queue_fleet_projection.Unknown
       Keeper_event_queue_fleet_projection.First_admission_not_recorded -> ()
   | Keeper_event_queue_fleet_projection.Empty ->
     fail "unclocked selections must not read as an empty queue"
   | Keeper_event_queue_fleet_projection.Unknown
       (Keeper_event_queue_fleet_projection.Queue_observation_incomplete
       | Keeper_event_queue_fleet_projection.Clock_observation_invalid) ->
     fail "unclocked selections must name the missing clock"
   | Keeper_event_queue_fleet_projection.Observed _ ->
     fail "unclocked selections must not read as observed");
  let json =
    Keeper_event_queue_fleet_projection.queue_residence_to_yojson residence
  in
  check string "residence is unknown" "unknown" (json_string_member "status" json);
  check string "reason names the missing clock" "first_admission_not_recorded"
    (json_string_member "reason" json);
  check bool "no age is invented" true (U.member "oldest_age_seconds" json = `Null)
;;

let test_queue_residence_of_an_empty_queue_is_empty () =
  with_workspace
  @@ fun config ->
  let keeper_name = "queue-residence-empty-keeper" in
  ensure_keeper config keeper_name;
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  let _, residence = queue_residence_of_keeper json keeper_name in
  check string "residence is empty" "empty" (json_string_member "status" residence)
;;

let test_public_board_rows_withhold_unverified_identity () = with_workspace @@ fun config ->
  let keeper_name = "public-board-inventory" in
  ensure_keeper config keeper_name;
  let private_marker = "PRIVATE_INVENTORY_" in
  let private_value field = private_marker ^ field in
  let kinds = Keeper_event_queue.
    [Post_created; Post_updated {content_updated_at = 2.};
     Comment_added {comment_id = private_value "COMMENT_ID"; parent_id = Some (private_value "PARENT_ID")};
     Reaction_changed {target_type = Reaction_comment; target_id = private_value "REACTION_ID";
       user_id = private_value "REACTOR"; emoji = private_value "EMOJI"; reacted = true};
     Vote_cast {target = Vote_on_comment (private_value "VOTE_ID");
       target_author = private_value "TARGET_AUTHOR"; voter = private_value "VOTER";
       direction = Vote_up}] in
  let stimuli = List.mapi (fun kind_index kind ->
    let board : Keeper_event_queue.board_stimulus =
      {kind; author = private_value "AUTHOR"; title = private_value "TITLE";
       content = private_value "BODY"; hearth = Some (private_value "HEARTH");
       updated_at = Some 2.; audience = Audience_targets [private_value "READER"]} in
    let payloads = Keeper_event_queue.
      [Board_signal board; Board_attention {candidate_id = private_value "CANDIDATE_ID"; signal = board};
       Board_routing_pending board] in
    List.mapi (fun variant_index payload ->
      stimulus ~post_id:(Printf.sprintf "%sPOST_%d_%d" private_marker kind_index variant_index)
        ~arrived_at:100. payload) payloads) kinds |> List.concat in
  Keeper_event_queue_persistence.persist ~base_path:config.Workspace_utils_backend_setup.base_path
    ~keeper_name (queue_of_list stimuli);
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  let rows = U.(json |> member "rows" |> to_list) in
  check int "all Board variants remain counted as waiting work" 15 (List.length rows);
  List.iter (fun row ->
    check string "public Board sentence carries no event actor" "Board 알림 대기"
      (json_string_member "what" row);
    let fields = U.(row |> member "detail" |> to_assoc) in
    check (list string) "public Board details expose only opaque control addresses"
      ["source_incarnation"; "source_ref"]
      (List.map fst fields |> List.sort String.compare)) rows;
  let rec strings = function
    | `String value -> [value]
    | `List values -> List.concat_map strings values
    | `Assoc fields -> List.concat_map (fun (_, value) -> strings value) fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ -> [] in
  check bool "flat and per-Keeper public DTOs contain no captured Board identifiers" false
    (List.exists (Astring.String.is_infix ~affix:private_marker) (strings json));
  let restored = match Keeper_event_queue_persistence.load_state_result
      ~base_path:config.Workspace_utils_backend_setup.base_path ~keeper_name with
    | Ok state -> state | Error detail -> fail detail in
  check int "public redaction leaves private queue originals available to authorized controls" 15
    (Keeper_event_queue_state.pending_selections restored |> List.length);
  List.iter (fun row ->
    let detail = U.member "detail" row in
    match Keeper_event_queue_state.resolve_pending_selection
      ~source_ref:(json_string_member "source_ref" detail)
      ~source_incarnation:(Int64.of_string (json_string_member "source_incarnation" detail)) restored with
    | Ok _ -> ()
    | Error detail -> fail ("opaque Board address lost the exact authorized selection: " ^ detail)) rows
;;

let () =
  run "keeper_waiting_inventory"
    [ ( "queue_residence"
      , [ test_case "residence is the admission time, not the source time" `Quick
            test_queue_residence_is_the_admission_time_not_the_source_time
        ; test_case "residence without a recorded clock is unknown" `Quick
            test_queue_residence_without_a_recorded_clock_is_unknown
        ; test_case "residence of an empty queue is empty" `Quick
            test_queue_residence_of_an_empty_queue_is_empty
        ] )
    ; ( "dashboard_json"
      , [ test_case "public Board rows withhold unverified event identity" `Quick
            test_public_board_rows_withhold_unverified_identity
        ; test_case "event queue pending is visible" `Quick
            test_event_queue_pending_is_visible
        ; test_case "a settled composition row names what finished" `Quick
            test_settled_composition_row_names_what_finished
        ; test_case "event queue rows carry operator-visible payload fields" `Quick
            test_event_queue_pending_rows_carry_operator_visible_fields
        ; test_case "keeper-scoped projection excludes other keepers" `Quick
            test_keeper_scoped_projection_excludes_other_keepers
        ; test_case "Owner shutdown row is deferred" `Quick
            test_owner_shutdown_row_is_deferred
        ; test_case "shutdown next action follows the recorded operation" `Quick
            test_shutdown_next_action_follows_durable_operation
        ; test_case "unreadable shutdown preserves fence and storage failure" `Quick
            test_unreadable_shutdown_keeps_fence_and_read_error
        ; test_case "keeper-owned schedule rows are lane scoped" `Quick
            test_keeper_owned_schedule_waiting_rows_are_lane_scoped
        ; test_case "scoped schedules preserve participants" `Quick test_scoped_schedules_keep_participant_identity
        ; test_case "scoped confirmations preserve targets" `Quick test_scoped_confirmations_keep_target_identity
        ; test_case "nonlive keeper has no current execution" `Quick test_nonlive_keeper_has_no_current_execution
        ; test_case "live turn keeper is busy without waiting rows" `Quick
            test_live_turn_keeper_is_busy_without_waiting_rows
        ; test_case "every candidate spent waits for the earliest reset" `Quick
            test_every_candidate_spent_waits_for_the_earliest_reset
        ; test_case "quota spent needs every candidate and a running keeper" `Quick
            test_quota_spent_needs_every_candidate_and_a_running_keeper
        ; test_case "corrupt schedule ledger is read_error" `Quick
            test_corrupt_schedule_ledger_is_read_error
        ; test_case "keeper name discovery failure is read_error" `Quick
            test_keeper_name_discovery_failure_is_read_error
        ; test_case "corrupt external attention is read_error" `Quick
            test_corrupt_external_attention_is_read_error
        ; test_case "global pending confirm is actionable row" `Quick
            test_global_pending_confirm_is_actionable_row
        ; test_case "corrupt pending confirms is read_error" `Quick
            test_corrupt_pending_confirms_is_read_error
        ; test_case "unavailable pending approval store is read_error" `Quick
            test_unavailable_pending_approval_store_is_read_error
        ; test_case "health counts waiting without alarm" `Quick test_health_counts_normal_waiting_without_alarm
        ; test_case "health preserves recovery observation with unknown totals" `Quick test_health_retains_recovery_observation_without_known_totals
        ; test_case "health source failures remain unknown and redacted" `Quick test_health_partial_source_failure_and_exception_are_not_empty
        ; test_case "health placeholder has unknown counts" `Quick test_health_placeholder_has_unknown_counts
        ] )
    ]
;;
