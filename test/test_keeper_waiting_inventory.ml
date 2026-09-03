open Alcotest
module U = Yojson.Safe.Util
module Keeper_chat_store = Masc.Keeper_chat_store
module Keeper_external_attention = Masc.Keeper_external_attention
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_owner_registry = Masc.Keeper_owner_registry
module Keeper_registry = Masc.Keeper_registry
module Keeper_shutdown_types = Masc.Keeper_shutdown_types
module Keeper_types_profile = Masc.Keeper_types_profile
module Otel_metric_store = Masc.Otel_metric_store
module Server_keeper_waiting_inventory = Masc.Server_keeper_waiting_inventory

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

let record_external_attention_exn config ~keeper_name index =
  match
    Keeper_external_attention.record
      ~base_path:config.Workspace_utils_backend_setup.base_path
      (external_attention_item ~keeper_name index)
  with
  | `Recorded -> ()
  | `Duplicate _ -> failf "duplicate external attention item: %d" index
  | `Error err -> fail ("external attention record failed: " ^ err)
;;

let create_schedule_exn config ~schedule_id ~scheduled_by =
  match
    Schedule_service.create
      config
      ~schedule_id
      ~requested_at:100.0
      ~requested_by:(human "operator")
      ~scheduled_by
      ~due_at:200.0
      ~payload:schedule_payload
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
    ; cc_tool = "keeper_compose_background-snapshot"
    ; cc_terminal = Keeper_event_queue.Composition_failed "node board: store unavailable"
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
         "keeper_compose_background-snapshot 실패 · kmsg-bbb"
         (json_string_member "what" row);
       let detail = U.member "detail" row in
       check string "the typed payload label survives" "keeper_composition_completed"
         (json_string_member "payload_kind" detail);
       (* The two fields an operator needs to go read the result itself. *)
       check string "the request id to read the result with" "kmsg-bbb"
         (json_string_member "composition_request_id" detail);
       check string "and the tool that produced it"
         "keeper_compose_background-snapshot"
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
  check string "schema" "masc.dashboard.keeper_waiting_inventory.v3"
    (json_string_member "schema" json);
  check int "one keeper" 1 (json_int_member "keeper_count" json);
  check int "one waiting keeper" 1 (json_int_member "waiting_keeper_count" json);
  check int "one row" 1 (json_int_member "row_count" json);
  match find_keeper json keeper_name with
  | None -> fail "keeper row missing"
  | Some keeper ->
    check string "state" "waiting" (json_string_member "state" keeper);
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
          }
          : Keeper_event_queue.board_stimulus))
  in
  Keeper_event_queue_persistence.persist
    ~base_path:config.Workspace_utils_backend_setup.base_path
    ~keeper_name
    (queue_of_list [ message; cancelled; rejected; board ]);
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
      String.equal post_id U.(row |> member "detail" |> member "post_id" |> to_string))
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
  check string "board sentence names the author, not the content"
    "operator의 새 글"
    (what_of board.Keeper_event_queue.post_id);
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
  let board_detail = detail_of board.Keeper_event_queue.post_id in
  check string "board row keeps only the typed payload label" "board_signal"
    (json_string_member "payload_kind" board_detail);
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
            check string "shutdown row next action" "keeper_shutdown_finalize"
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
      Keeper_registry.mark_turn_started
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
  let error : Masc.Keeper_approval_queue.storage_error =
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

let () =
  run "keeper_waiting_inventory"
    [ ( "dashboard_json"
      , [ test_case "event queue pending is visible" `Quick
            test_event_queue_pending_is_visible
        ; test_case "a settled composition row names what finished" `Quick
            test_settled_composition_row_names_what_finished
        ; test_case "event queue rows carry operator-visible payload fields" `Quick
            test_event_queue_pending_rows_carry_operator_visible_fields
        ; test_case "keeper-scoped projection excludes other keepers" `Quick
            test_keeper_scoped_projection_excludes_other_keepers
        ; test_case "Owner shutdown row is deferred" `Quick
            test_owner_shutdown_row_is_deferred
        ; test_case "keeper-owned schedule rows are lane scoped" `Quick
            test_keeper_owned_schedule_waiting_rows_are_lane_scoped
        ; test_case "live turn keeper is busy without waiting rows" `Quick
            test_live_turn_keeper_is_busy_without_waiting_rows
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
        ] )
    ]
;;
