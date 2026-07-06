open Alcotest
module U = Yojson.Safe.Util
module Keeper_meta_store = Masc.Keeper_meta_store

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
  f config
;;

let operator_pending_confirms_path config =
  Filename.concat
    (Filename.concat (Workspace.masc_dir config) "operator")
    "pending_confirms.json"
;;

let keeper_meta_fixture keeper_name =
  Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [ "name", `String keeper_name
      ; "agent_name", `String keeper_name
      ; "goal", `String "waiting inventory test"
      ; "sandbox_profile", `String "local"
      ; "network_mode", `String "inherit"
      ])
;;

let ensure_keeper config keeper_name =
  match Result.bind (keeper_meta_fixture keeper_name) (Keeper_meta_store.write_meta config) with
  | Ok _ -> ()
  | Error err -> fail ("write keeper meta failed: " ^ err)
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
    ; "schema_version", `Int 1
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
      ~base_path:config.Workspace.base_path
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
      ~risk_class:Schedule_domain.Read_only
      ~source:Schedule_domain.Operator_request
      ()
  with
  | Ok request -> request
  | Error err ->
    fail ("schedule create failed: " ^ Schedule_service.service_error_to_string err)
;;

let test_event_queue_pending_and_inflight_are_visible () =
  with_workspace
  @@ fun config ->
  let keeper_name = "waiting-inventory-keeper" in
  ensure_keeper config keeper_name;
  let pending =
    stimulus ~post_id:"pending-1" ~arrived_at:100.0 Keeper_event_queue.Bootstrap
  in
  let inflight =
    stimulus ~post_id:"inflight-1" ~arrived_at:110.0 Keeper_event_queue.No_progress_recovery
  in
  Keeper_event_queue_persistence.persist ~base_path:config.base_path ~keeper_name
    (queue_of_list [ pending ]);
  Keeper_event_queue_persistence.record_inflight ~base_path:config.base_path
    ~keeper_name [ inflight ];
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check_metric_float "event pending metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "keeper"; "source", "event_queue_pending" ]
    1.0;
  check_metric_float "event inflight metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "keeper"; "source", "event_queue_inflight" ]
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
  check string "schema" "masc.dashboard.keeper_waiting_inventory.v1"
    (json_string_member "schema" json);
  check int "one keeper" 1 (json_int_member "keeper_count" json);
  check int "one waiting keeper" 1 (json_int_member "waiting_keeper_count" json);
  check int "two rows" 2 (json_int_member "row_count" json);
  match find_keeper json keeper_name with
  | None -> fail "keeper row missing"
  | Some keeper ->
    check string "state" "waiting" (json_string_member "state" keeper);
    check int "waiting count" 2 (json_int_member "waiting_count" keeper);
    check int "pending source" 1 U.(keeper |> member "sources" |> member "event_queue_pending" |> to_int);
    check int "inflight source" 1 U.(keeper |> member "sources" |> member "event_queue_inflight" |> to_int);
    (match U.(keeper |> member "waiting_on" |> to_list) with
     | pending_row :: inflight_row :: _ ->
       check string "pending wake producer" "keeper_supervisor"
         (json_string_member "wake_producer" pending_row);
       check string "inflight wake producer" "keeper_no_progress_recovery"
        (json_string_member "wake_producer" inflight_row)
     | rows -> failf "expected two queue rows, got %d" (List.length rows))
;;

let test_chat_queue_pending_rows_are_visible () =
  with_workspace
  @@ fun config ->
  let keeper_name = "queued-chat-keeper" in
  ensure_keeper config keeper_name;
  Keeper_chat_queue.For_testing.reset ();
  let message : Keeper_chat_queue.queued_message =
    { content = "queued while busy"
    ; user_blocks = []
    ; attachments = []
    ; timestamp = 150.0
    ; source = Keeper_chat_queue.Discord { channel_id = "chan-42"; user_id = "user-7" }
    }
  in
  Keeper_chat_queue.enqueue ~keeper_name message;
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check_metric_float "chat queue metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "keeper"; "source", "chat_queue_pending" ]
    1.0;
  check int "one keeper row" 1 (json_int_member "row_count" json);
  (match find_keeper json keeper_name with
   | None -> fail "keeper row missing"
   | Some keeper ->
     check string "keeper state" "waiting" (json_string_member "state" keeper);
     check int "keeper waiting count" 1 (json_int_member "waiting_count" keeper);
     check int "chat queue source" 1
       U.(keeper |> member "sources" |> member "chat_queue_pending" |> to_int);
     (match U.(keeper |> member "waiting_on" |> to_list) with
      | [ row ] ->
        check string "chat queue source row" "chat_queue_pending"
          (json_string_member "source" row);
        check string "chat queue wake producer" "keeper_chat_queue_store"
          (json_string_member "wake_producer" row);
        check string "chat queue next action" "keeper_chat_consumer_drain"
          (json_string_member "next_action" row);
        check string "chat queue waiting_on" "discord"
          (json_string_member "waiting_on" row);
        check string "chat queue source kind" "discord"
          U.(row |> member "detail" |> member "message_source" |> member "kind" |> to_string);
        check string "chat queue channel" "chan-42"
          U.(
            row |> member "detail" |> member "message_source" |> member "channel_id"
            |> to_string);
        check int "chat queue content length" (String.length message.content)
          U.(row |> member "detail" |> member "content_length" |> to_int)
      | rows -> failf "expected one chat queue row, got %d" (List.length rows)))
;;

let test_turn_admission_waiting_row_is_visible () =
  with_workspace
  @@ fun config ->
  let keeper_name = "admission-waiting-keeper" in
  ensure_keeper config keeper_name;
  Keeper_turn_admission.For_testing.reset ();
  Fun.protect
    ~finally:(fun () -> Keeper_turn_admission.For_testing.reset ())
    (fun () ->
      Eio.Switch.run
      @@ fun sw ->
      let autonomous_started, set_autonomous_started = Eio.Promise.create () in
      let release_autonomous, set_release_autonomous = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        match
          Keeper_turn_admission.run_if_free ~base_path:config.base_path ~keeper_name
            (fun () ->
               Eio.Promise.resolve set_autonomous_started ();
               Eio.Promise.await release_autonomous)
        with
        | `Ran () -> ()
        | `Busy _ -> fail "autonomous holder must admit on a free slot");
      Eio.Promise.await autonomous_started;
      Eio.Fiber.fork ~sw (fun () ->
        match
          Keeper_turn_admission.run_serialized ~base_path:config.base_path
            ~keeper_name
            (fun () -> ())
        with
        | `Ran () -> ()
        | `Rejected _ -> fail "parked chat must not reject below the cap");
      Eio.Fiber.yield ();
      let json = Server_keeper_waiting_inventory.dashboard_json config in
      check_metric_float "turn admission waiting metric"
        Otel_metric_store.metric_keeper_waiting_count
        ~labels:[ "scope", "keeper"; "source", "turn_admission_waiting" ]
        1.0;
      check int "one keeper row" 1 (json_int_member "row_count" json);
      (match find_keeper json keeper_name with
       | None -> fail "keeper row missing"
       | Some keeper ->
         check string "keeper state" "waiting" (json_string_member "state" keeper);
         check int "keeper waiting count" 1 (json_int_member "waiting_count" keeper);
         check int "turn admission source" 1
           U.(keeper |> member "sources" |> member "turn_admission_waiting" |> to_int);
         (match U.(keeper |> member "waiting_on" |> to_list) with
          | [ row ] ->
            check string "turn admission row source" "turn_admission_waiting"
              (json_string_member "source" row);
            check string "turn admission wake producer" "keeper_turn_admission"
              (json_string_member "wake_producer" row);
            check string "turn admission next action" "turn_slot_release"
              (json_string_member "next_action" row);
            check string "turn admission waiting_on" "chat"
              (json_string_member "waiting_on" row);
            check bool "turn admission since is recorded" true
              (U.(row |> member "since" |> to_float) > 0.0);
            check string "waiting lane" "chat"
              U.(row |> member "detail" |> member "waiting_lane" |> to_string);
            check bool "detail waiting_since is recorded" true
              (U.(row |> member "detail" |> member "waiting_since" |> to_float) > 0.0);
            check string "in-flight lane" "autonomous"
              U.(row |> member "detail" |> member "in_flight" |> member "lane" |> to_string)
          | rows -> failf "expected one turn admission row, got %d" (List.length rows)));
      Eio.Promise.resolve set_release_autonomous ())
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
          U.(row |> member "detail" |> member "schedule_id" |> to_string)
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
  Keeper_registry.clear ();
  Fun.protect
    ~finally:(fun () -> Keeper_registry.clear ())
    (fun () ->
      ignore (Keeper_registry.register ~base_path:config.base_path keeper_name meta);
      Keeper_registry.mark_turn_started ~base_path:config.base_path keeper_name;
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

let test_corrupt_schedule_ledger_is_read_error () =
  with_workspace
  @@ fun config ->
  save_text (Schedule_store.schedules_path config) "{not-json";
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
    (Keeper_external_attention.attention_path ~base_path:config.base_path ~keeper_name)
    "{not-json\n";
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check_metric_float "keeper external-attention read error metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "keeper"; "source", "read_error" ]
    1.0;
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

let test_external_attention_projection_is_bounded () =
  with_workspace
  @@ fun config ->
  let keeper_name = "external-attention-bounded-keeper" in
  ensure_keeper config keeper_name;
  let initial_json = Server_keeper_waiting_inventory.dashboard_json config in
  let limit = json_int_member "external_attention_row_limit" initial_json in
  check bool "external attention row limit is positive" true (limit > 0);
  for index = 1 to limit + 1 do
    record_external_attention_exn config ~keeper_name index
  done;
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check bool "root row count reports truncation" true
    (json_bool_member "row_count_truncated" json);
  check int "one keeper has truncated external attention" 1
    (json_int_member "external_attention_truncated_keeper_count" json);
  check int "row count is capped" limit (json_int_member "row_count" json);
  match find_keeper json keeper_name with
  | None -> fail "keeper row missing"
  | Some keeper ->
    check bool "keeper waiting count reports truncation" true
      (json_bool_member "waiting_count_truncated" keeper);
    check bool "external attention source reports truncation" true
      U.(keeper |> member "truncated_sources" |> member "external_attention" |> to_bool);
    check int "keeper waiting count is capped" limit
      (json_int_member "waiting_count" keeper);
    check int "keeper waiting rows are capped" limit
      U.(keeper |> member "waiting_on" |> to_list |> List.length)
;;

let test_corrupt_pending_confirms_is_read_error () =
  with_workspace
  @@ fun config ->
  save_text (operator_pending_confirms_path config) "{not-json";
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

let () =
  run "keeper_waiting_inventory"
    [ ( "dashboard_json"
      , [ test_case "event queue pending and inflight are visible" `Quick
            test_event_queue_pending_and_inflight_are_visible
        ; test_case "chat queue pending rows are visible" `Quick
            test_chat_queue_pending_rows_are_visible
        ; test_case "turn admission waiting row is visible" `Quick
            test_turn_admission_waiting_row_is_visible
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
        ; test_case "external attention projection is bounded" `Quick
            test_external_attention_projection_is_bounded
        ; test_case "corrupt pending confirms is read_error" `Quick
            test_corrupt_pending_confirms_is_read_error
        ] )
    ]
;;
