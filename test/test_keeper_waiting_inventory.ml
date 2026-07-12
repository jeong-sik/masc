open Alcotest
module U = Yojson.Safe.Util
module Keeper_chat_queue = Masc.Keeper_chat_queue
module Keeper_chat_store = Masc.Keeper_chat_store
module Keeper_external_attention = Masc.Keeper_external_attention
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_registry = Masc.Keeper_registry
module Keeper_shutdown_types = Masc.Keeper_shutdown_types
module Keeper_turn_admission = Masc.Keeper_turn_admission
module Keeper_types_profile = Masc.Keeper_types_profile
module Otel_metric_store = Masc.Otel_metric_store
module Server_keeper_waiting_inventory = Masc.Server_keeper_waiting_inventory
module Surface_ref = Masc.Surface_ref

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
  Eio.Switch.on_release sw (fun () ->
    Keeper_chat_queue.For_testing.reset ();
    rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  Keeper_chat_queue.For_testing.reset ();
  let queue_report = Keeper_chat_queue.configure_persistence ~config in
  check int "chat queue persistence starts clean" 0
    (List.length queue_report.load_errors);
  f config
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
  Keeper_event_queue_persistence.persist
    ~base_path:config.Workspace_utils_backend_setup.base_path
    ~keeper_name
    (queue_of_list [ pending ]);
  Keeper_event_queue_persistence.record_inflight
    ~base_path:config.Workspace_utils_backend_setup.base_path
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
  check string "schema" "masc.dashboard.keeper_waiting_inventory.v2"
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
  let message : Keeper_chat_queue.queued_message =
    { content = "queued while busy"
    ; user_blocks = []
    ; attachments = []
    ; timestamp = 150.0
    ; source = Keeper_chat_queue.Discord { channel_id = "chan-42"; user_id = "user-7" }
    ; transcript_context =
        Some
          { surface =
              Surface_ref.Discord
                { guild_id = None
                ; channel_id = "chan-42"
                ; parent_channel_id = None
                ; thread_id = None
                }
          ; conversation_id = None
          ; external_message_id = None
          ; speaker =
              { Keeper_chat_store.speaker_id = Some "user-7"
              ; speaker_name = None
              ; speaker_authority = Keeper_chat_store.External
              }
          ; extra_mentions = []
          }
    }
  in
  let receipt =
    match Keeper_chat_queue.enqueue ~keeper_name message with
    | Ok receipt -> receipt
    | Error error ->
      fail
        ("chat queue enqueue failed: "
         ^ Keeper_chat_queue.mutation_error_to_string error)
  in
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
     let chat_queue = U.(keeper |> member "chat_queue") in
     check string "chat queue projection schema" "keeper_chat_queue.dashboard.v1"
       (json_string_member "schema" chat_queue);
     check int "chat queue pending projection count" 1
       (json_int_member "pending_count" chat_queue);
     check int "chat queue inflight projection count" 0
       (json_int_member "inflight_count" chat_queue);
     check string "chat queue projection next action" "keeper_chat_consumer_drain"
       U.(chat_queue |> member "next_action" |> to_string);
     (match U.(chat_queue |> member "active_receipts" |> to_list) with
      | [ active ] ->
        check string "active receipt id"
          (Keeper_chat_queue.Receipt_id.to_string receipt.receipt_id)
          (json_string_member "receipt_id" active);
        check string "active receipt state" "pending"
          (json_string_member "state" active);
        check bool "active prompt text is not projected" true
          U.(active |> member "dashboard_message" = `Null)
      | rows -> failf "expected one active chat receipt, got %d" (List.length rows));
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
          U.(row |> member "detail" |> member "content_length" |> to_int);
        check string "pending receipt is correlated"
          (Keeper_chat_queue.Receipt_id.to_string receipt.receipt_id)
          U.(row |> member "detail" |> member "receipt_id" |> to_string);
        check string "pending lifecycle is explicit" "pending"
          U.(row |> member "detail" |> member "lifecycle" |> member "state"
             |> to_string)
      | rows -> failf "expected one chat queue row, got %d" (List.length rows)));
  let tool_json = Server_keeper_waiting_inventory.tool_json config in
  check string "tool projection is explicitly redacted" "redacted"
    (json_string_member "visibility" tool_json);
  (match find_keeper tool_json keeper_name with
   | None -> fail "redacted tool keeper row missing"
   | Some keeper ->
     (match U.(keeper |> member "waiting_on" |> to_list) with
      | [ row ] ->
        let source = U.(row |> member "detail" |> member "message_source") in
        check string "tool keeps source kind" "discord"
          (json_string_member "kind" source);
        check bool "tool omits connector channel id" true
          U.(source |> member "channel_id" = `Null);
        check bool "tool omits connector user id" true
          U.(source |> member "user_id" = `Null)
      | rows -> failf "expected one redacted queue row, got %d" (List.length rows)));
  let lease =
    match Keeper_chat_queue.lease_batch ~keeper_name with
    | `Leased lease -> lease
    | `Empty | `Already_leased _ | `Error _ ->
      fail "pending chat receipt should lease"
  in
  let inflight_json = Server_keeper_waiting_inventory.dashboard_json config in
  (match find_keeper inflight_json keeper_name with
   | None -> fail "inflight keeper row missing"
   | Some keeper ->
    check int "pending source clears after lease" 0
      U.(keeper |> member "sources" |> member "chat_queue_pending" |> to_int_option
         |> Option.value ~default:0);
    check int "inflight source is visible" 1
      U.(keeper |> member "sources" |> member "chat_queue_inflight" |> to_int);
    let chat_queue = U.(keeper |> member "chat_queue") in
    check int "inflight projection pending count" 0
      (json_int_member "pending_count" chat_queue);
    check int "inflight projection count" 1
      (json_int_member "inflight_count" chat_queue);
    (match U.(chat_queue |> member "active_receipts" |> to_list) with
     | [ active ] ->
       check string "active inflight receipt state" "inflight"
         (json_string_member "state" active);
       check string "active inflight lease" lease.lease_id
         (json_string_member "lease_id" active)
     | rows -> failf "expected one inflight projection row, got %d" (List.length rows));
    (match U.(keeper |> member "waiting_on" |> to_list) with
     | [ row ] ->
       check string "inflight row source" "chat_queue_inflight"
         (json_string_member "source" row);
       check string "inflight lifecycle is explicit" "inflight"
         U.(row |> member "detail" |> member "lifecycle" |> member "state"
            |> to_string);
       check string "inflight lease is correlated" lease.lease_id
         U.(row |> member "detail" |> member "lifecycle" |> member "lease_id"
            |> to_string)
     | rows -> failf "expected one inflight chat row, got %d" (List.length rows)));
  (match
     Keeper_chat_queue.finalize ~keeper_name ~lease_id:lease.lease_id
       ~outcome:
         (Keeper_chat_queue.Mark_failed
            { completed_at = 200.0
            ; kind = Keeper_chat_queue.Turn_failed
            ; detail = "provider failed after queue acceptance"
            ; outcome_ref = None
            })
   with
   | `Finalized [ finalized ] ->
     check string "failed receipt finalized"
       (Keeper_chat_queue.Receipt_id.to_string receipt.receipt_id)
       (Keeper_chat_queue.Receipt_id.to_string finalized)
   | `Finalized rows -> failf "expected one finalized receipt, got %d" (List.length rows)
   | `Unknown_lease -> fail "failed receipt lease unexpectedly unknown"
   | `Error error ->
     fail
       ("failed receipt finalization failed: "
        ^ Keeper_chat_queue.mutation_error_to_string error));
  let failed_json = Server_keeper_waiting_inventory.dashboard_json config in
  match find_keeper failed_json keeper_name with
  | None -> fail "failed receipt keeper row missing"
  | Some keeper ->
    let chat_queue = U.(keeper |> member "chat_queue") in
    check int "failed receipt leaves active pending count" 0
      (json_int_member "pending_count" chat_queue);
    check int "failed receipt leaves active inflight count" 0
      (json_int_member "inflight_count" chat_queue);
    check int "failed receipt total is explicit" 1
      (json_int_member "recent_failed_receipt_count" chat_queue);
    check int "failed receipt projection limit is explicit" 8
      (json_int_member "recent_failed_receipt_limit" chat_queue);
    check bool "failed receipt projection is complete" false
      U.(chat_queue |> member "recent_failed_receipts_truncated" |> to_bool);
    (match U.(chat_queue |> member "recent_failed_receipts" |> to_list) with
     | [ failed ] ->
       check string "failed receipt remains discoverable"
         (Keeper_chat_queue.Receipt_id.to_string receipt.receipt_id)
         (json_string_member "receipt_id" failed);
       check string "failed receipt state" "failed"
         (json_string_member "state" failed);
       check string "failed receipt kind" "turn_failed"
         (json_string_member "failure_kind" failed);
       check bool "failed diagnostic detail is not projected" true
         U.(failed |> member "detail" = `Null)
     | rows -> failf "expected one recent failed receipt, got %d" (List.length rows))
;;

let test_chat_queue_inflight_priority_matches_structured_projection () =
  with_workspace
  @@ fun config ->
  let keeper_name = "queued-chat-mixed-state" in
  ensure_keeper config keeper_name;
  let queued content timestamp : Keeper_chat_queue.queued_message =
    { content
    ; user_blocks = []
    ; attachments = []
    ; timestamp
    ; source = Keeper_chat_queue.Dashboard
    ; transcript_context = None
    }
  in
  let first =
    match Keeper_chat_queue.enqueue ~keeper_name (queued "first" 100.0) with
    | Ok receipt -> receipt
    | Error error ->
      fail
        ("first enqueue failed: "
         ^ Keeper_chat_queue.mutation_error_to_string error)
  in
  let lease =
    match Keeper_chat_queue.lease_batch ~keeper_name with
    | `Leased lease -> lease
    | `Empty | `Already_leased _ | `Error _ -> fail "first receipt did not lease"
  in
  let second =
    match Keeper_chat_queue.enqueue ~keeper_name (queued "second" 110.0) with
    | Ok receipt -> receipt
    | Error error ->
      fail
        ("second enqueue failed: "
         ^ Keeper_chat_queue.mutation_error_to_string error)
  in
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  match find_keeper json keeper_name with
  | None -> fail "mixed-state keeper row missing"
  | Some keeper ->
    let chat_queue = U.(keeper |> member "chat_queue") in
    check string "keeper and chat projection share inflight next action"
      "keeper_chat_turn_terminal_receipt"
      (json_string_member "next_action" keeper);
    check string "structured chat projection prioritizes inflight"
      "keeper_chat_turn_terminal_receipt"
      (json_string_member "next_action" chat_queue);
    (match U.(keeper |> member "waiting_on" |> to_list) with
     | inflight :: pending :: _ ->
       check string "flat projection lists inflight first" "chat_queue_inflight"
         (json_string_member "source" inflight);
       check int "inflight queue index is zero" 0
         U.(inflight |> member "detail" |> member "queue_index" |> to_int);
       check string "flat projection lists pending second" "chat_queue_pending"
         (json_string_member "source" pending);
       check int "pending queue index follows inflight" 1
         U.(pending |> member "detail" |> member "queue_index" |> to_int)
     | rows -> failf "expected mixed chat rows, got %d" (List.length rows));
    (match U.(chat_queue |> member "active_receipts" |> to_list) with
     | inflight :: pending :: _ ->
       check string "active inflight receipt is first"
         (Keeper_chat_queue.Receipt_id.to_string first.receipt_id)
         (json_string_member "receipt_id" inflight);
       check string "active pending receipt is second"
         (Keeper_chat_queue.Receipt_id.to_string second.receipt_id)
         (json_string_member "receipt_id" pending)
     | rows -> failf "expected mixed active receipts, got %d" (List.length rows));
    ignore lease
;;

let test_recent_failed_chat_projection_is_bounded_and_newest_first () =
  with_workspace
  @@ fun config ->
  let keeper_name = "bounded-failed-chat-keeper" in
  ensure_keeper config keeper_name;
  let expected_newest_first = ref [] in
  for ordinal = 0 to 9 do
    let message : Keeper_chat_queue.queued_message =
      { content = Printf.sprintf "private queued prompt %d" ordinal
      ; user_blocks = []
      ; attachments = []
      ; timestamp = Float.of_int ordinal
      ; source = Keeper_chat_queue.Dashboard
      ; transcript_context = None
      }
    in
    let receipt =
      match Keeper_chat_queue.enqueue ~keeper_name message with
      | Ok receipt -> receipt
      | Error error ->
        fail
          ("chat queue enqueue failed: "
           ^ Keeper_chat_queue.mutation_error_to_string error)
    in
    let lease =
      match Keeper_chat_queue.lease_batch ~keeper_name with
      | `Leased lease -> lease
      | `Empty | `Already_leased _ | `Error _ ->
        fail "fresh chat receipt should lease"
    in
    let completed_at = 1_000.0 +. Float.of_int ordinal in
    (match
       Keeper_chat_queue.finalize ~keeper_name ~lease_id:lease.lease_id
         ~outcome:
           (Keeper_chat_queue.Mark_failed
              { completed_at
              ; kind = Keeper_chat_queue.Turn_failed
              ; detail = Printf.sprintf "private failure detail %d" ordinal
              ; outcome_ref = None
              })
     with
     | `Finalized [ _ ] -> ()
     | `Finalized rows ->
       failf "expected one finalized receipt, got %d" (List.length rows)
     | `Unknown_lease -> fail "fresh chat receipt lease unexpectedly unknown"
     | `Error error ->
       fail
         ("failed receipt finalization failed: "
          ^ Keeper_chat_queue.mutation_error_to_string error));
    expected_newest_first :=
      Keeper_chat_queue.Receipt_id.to_string receipt.receipt_id
      :: !expected_newest_first
  done;
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  match find_keeper json keeper_name with
  | None -> fail "failed receipt keeper row missing"
  | Some keeper ->
    let chat_queue = U.(keeper |> member "chat_queue") in
    check int "total failure count" 10
      (json_int_member "recent_failed_receipt_count" chat_queue);
    check bool "bounded projection is explicitly truncated" true
      U.(chat_queue |> member "recent_failed_receipts_truncated" |> to_bool);
    let projected =
      U.(chat_queue |> member "recent_failed_receipts" |> to_list)
      |> List.map (json_string_member "receipt_id")
    in
    let rec take remaining = function
      | _ when remaining <= 0 -> []
      | [] -> []
      | row :: rows -> row :: take (remaining - 1) rows
    in
    let expected = take 8 !expected_newest_first in
    check (list string) "newest eight failures" expected projected;
    List.iter
      (fun row ->
         check bool "bounded failure never exposes detail" true
           U.(row |> member "detail" = `Null))
      U.(chat_queue |> member "recent_failed_receipts" |> to_list)
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
          Keeper_turn_admission.run_if_free
            ~base_path:config.Workspace_utils_backend_setup.base_path
            ~keeper_name
            (fun () ->
               Eio.Promise.resolve set_autonomous_started ();
               Eio.Promise.await release_autonomous)
        with
        | `Ran () -> ()
        | `Busy _ -> fail "autonomous holder must admit on a free slot");
      Eio.Promise.await autonomous_started;
      Eio.Fiber.fork ~sw (fun () ->
        match
          Keeper_turn_admission.run_serialized
            ~base_path:config.Workspace_utils_backend_setup.base_path
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

let test_turn_admission_shutdown_row_is_deferred () =
  with_workspace
  @@ fun config ->
  let keeper_name = "admission-shutdown-keeper" in
  ensure_keeper config keeper_name;
  Keeper_turn_admission.For_testing.reset ();
  Fun.protect
    ~finally:(fun () -> Keeper_turn_admission.For_testing.reset ())
    (fun () ->
      let base_path = config.Workspace_utils_backend_setup.base_path in
      let operation_id = Keeper_shutdown_types.Operation_id.generate () in
      (match
         Keeper_turn_admission.begin_shutdown
           ~base_path
           ~keeper_name
           ~operation_id
       with
       | Keeper_turn_admission.Shutdown_reserved reservation ->
         check bool "shutdown reservation is idle" true
           (Option.is_none reservation.in_flight)
       | Keeper_turn_admission.Shutdown_already_reserved _ ->
         fail "fresh keeper unexpectedly had a shutdown reservation");
      let json = Server_keeper_waiting_inventory.dashboard_json config in
      check_metric_float "turn admission shutdown metric"
        Otel_metric_store.metric_keeper_waiting_count
        ~labels:[ "scope", "keeper"; "source", "turn_admission_shutdown" ]
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
           U.(keeper |> member "sources" |> member "turn_admission_shutdown" |> to_int);
         (match U.(keeper |> member "waiting_on" |> to_list) with
          | [ row ] ->
            check string "shutdown row source" "turn_admission_shutdown"
              (json_string_member "source" row);
            check string "shutdown row waiting_on" "shutdown"
              (json_string_member "waiting_on" row);
            check string "shutdown row wake producer" "keeper_turn_admission"
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
            check int "shutdown has no waiting chat" 0
              U.(row |> member "detail" |> member "chat_waiting_count" |> to_int);
            check bool "shutdown has no in-flight turn" true
              U.(row |> member "detail" |> member "in_flight" = `Null)
          | rows -> failf "expected one shutdown row, got %d" (List.length rows)));
      (match
         Keeper_turn_admission.rollback_shutdown
           ~base_path
           ~keeper_name
           ~operation_id
       with
       | Keeper_turn_admission.Shutdown_rolled_back -> ()
       | Keeper_turn_admission.Shutdown_not_reserved
       | Keeper_turn_admission.Shutdown_reserved_by_other _ ->
         fail "owned shutdown reservation did not roll back");
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
      ignore
        (Keeper_registry.register
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

let test_corrupt_chat_queue_snapshot_is_read_error () =
  with_workspace
  @@ fun config ->
  let keeper_name = "corrupt-chat-queue-keeper" in
  ensure_keeper config keeper_name;
  let path =
    Filename.concat
      (Filename.concat
         (Workspace_core.keepers_runtime_dir config)
         keeper_name)
      "chat-queue.json"
  in
  save_text path "{not-json";
  let report = Keeper_chat_queue.configure_persistence ~config in
  check int "corrupt chat queue is reported at configure" 1
    (List.length report.load_errors);
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  let tool_json = Server_keeper_waiting_inventory.tool_json config in
  (match find_keeper tool_json keeper_name with
   | None -> fail "corrupt queue tool row missing"
   | Some keeper ->
     let chat_queue = U.(keeper |> member "chat_queue") in
     (match U.(chat_queue |> member "read_errors" |> to_list) with
      | [ error ] ->
        check string "tool keeps queue read-error kind" "parse_failed"
          (json_string_member "kind" error);
        check bool "tool omits queue error path" true
          U.(error |> member "path" = `Null);
        check bool "tool omits queue error message" true
          U.(error |> member "message" = `Null)
      | errors ->
        failf "expected one redacted queue read error, got %d"
          (List.length errors)));
  match find_keeper json keeper_name with
  | None -> fail "corrupt chat queue keeper row missing"
  | Some keeper ->
    check int "corrupt queue projects one read error" 1
      U.(keeper |> member "sources" |> member "read_error" |> to_int);
    let chat_queue = U.(keeper |> member "chat_queue") in
    check string "chat queue repair action is source-specific"
      "repair_keeper_chat_queue_snapshot"
      U.(chat_queue |> member "next_action" |> to_string);
    (match U.(chat_queue |> member "read_errors" |> to_list) with
     | [ error ] ->
       check string "chat queue read error kind" "parse_failed"
         (json_string_member "kind" error)
     | errors -> failf "expected one chat queue read error, got %d" (List.length errors));
    (match U.(keeper |> member "waiting_on" |> to_list) with
     | [ row ] ->
       check string "corrupt queue waiting_on" "chat_queue_snapshot"
         (json_string_member "waiting_on" row);
       check string "corrupt queue repair action"
         "repair_keeper_chat_queue_snapshot"
         (json_string_member "next_action" row)
     | rows -> failf "expected one corrupt chat queue row, got %d" (List.length rows))
;;

let test_queue_only_keeper_is_not_hidden_by_meta_inventory () =
  with_workspace
  @@ fun config ->
  let keeper_name = "queue-only-keeper" in
  let message : Keeper_chat_queue.queued_message =
    { content = "orphaned but durable"
    ; user_blocks = []
    ; attachments = []
    ; timestamp = 155.0
    ; source = Keeper_chat_queue.Dashboard
    ; transcript_context = None
    }
  in
  (match Keeper_chat_queue.enqueue ~keeper_name message with
   | Ok _ -> ()
   | Error error ->
     fail
       ("queue-only enqueue failed: "
        ^ Keeper_chat_queue.mutation_error_to_string error));
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  match find_keeper json keeper_name with
  | None -> fail "queue-only Keeper disappeared from inventory"
  | Some keeper ->
    check string "queue-only Keeper is typed" "queue_only"
      (json_string_member "metadata_status" keeper);
    check int "queue-only receipt remains visible" 1
      U.(keeper |> member "chat_queue" |> member "pending_count" |> to_int)
;;

let test_global_queue_configuration_error_without_meta_is_visible () =
  with_workspace
  @@ fun config ->
  let invalid_name = "invalid keeper name" in
  let path =
    Filename.concat
      (Filename.concat
         (Workspace_core.keepers_runtime_dir config)
         invalid_name)
      "chat-queue.json"
  in
  save_text path "{}";
  let report = Keeper_chat_queue.configure_persistence ~config in
  check int "invalid snapshot-bearing name is reported" 1
    (List.length report.load_errors);
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check int "global queue configuration error is visible" 1
    (json_int_member "global_row_count" json);
  match U.(json |> member "global_waiting_on" |> to_list) with
  | [ row ] ->
    check string "global queue error has a typed wait reason"
      "chat_queue_configuration"
      (json_string_member "waiting_on" row);
    check string "global queue error has a repair action"
      "repair_keeper_chat_queue_configuration"
      (json_string_member "next_action" row)
  | rows -> failf "expected one global queue error, got %d" (List.length rows)
;;

let pending_confirm_fixture ?(target_type = "goal") ?target_id ()
      : Operator_pending_confirm.pending_confirm
  =
  { token = "confirm-goal-1"
  ; trace_id = "trace-goal-1"
  ; actor = "operator"
  ; action_type = "approve_goal"
  ; target_type
  ; target_id
  ; payload = `Assoc [ "goal_id", `String "goal-123" ]
  ; delegated_tool = "masc_goal_approve"
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

let test_global_pending_confirm_is_actionable_row () =
  with_workspace
  @@ fun config ->
  ensure_keeper config "known-keeper";
  write_pending_confirms_exn
    config
    [ pending_confirm_fixture ~target_id:"goal-123" () ];
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
    check string "waiting_on" "approve_goal" (json_string_member "waiting_on" row);
    check string "wake producer" "operator_pending_confirm_store"
      (json_string_member "wake_producer" row);
    check string "next action" "operator_confirm_action"
      (json_string_member "next_action" row);
    check string "token" "confirm-goal-1" U.(detail |> member "token" |> to_string);
    check string "trace_id" "trace-goal-1" U.(detail |> member "trace_id" |> to_string);
    check string "target_type" "goal" U.(detail |> member "target_type" |> to_string);
    check string "target_id" "goal-123" U.(detail |> member "target_id" |> to_string);
    check string "delegated_tool" "masc_goal_approve"
      U.(detail |> member "delegated_tool" |> to_string)
  | rows -> failf "expected one global pending-confirm row, got %d" (List.length rows)
;;

let test_goal_pending_confirm_id_collision_stays_global () =
  with_workspace
  @@ fun config ->
  let keeper_name = "colliding-keeper" in
  ensure_keeper config keeper_name;
  write_pending_confirms_exn
    config
    [ pending_confirm_fixture ~target_type:"goal" ~target_id:keeper_name () ];
  let json = Server_keeper_waiting_inventory.dashboard_json config in
  check_metric_float "global collision pending-confirm metric"
    Otel_metric_store.metric_keeper_waiting_count
    ~labels:[ "scope", "global"; "source", "operator_pending_confirm" ]
    1.0;
  check int "global collision pending-confirm row" 1
    (json_int_member "global_row_count" json);
  (match find_keeper json keeper_name with
   | None -> fail "keeper row missing"
   | Some keeper ->
     check int "keeper lane remains empty" 0 (json_int_member "waiting_count" keeper));
  match U.(json |> member "global_waiting_on" |> to_list) with
  | [ row ] ->
    let detail = U.(row |> member "detail") in
    check string "source" "operator_pending_confirm" (json_string_member "source" row);
    check string "target_type" "goal" U.(detail |> member "target_type" |> to_string);
    check string "target_id" keeper_name U.(detail |> member "target_id" |> to_string)
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

let () =
  run "keeper_waiting_inventory"
    [ ( "dashboard_json"
      , [ test_case "event queue pending and inflight are visible" `Quick
            test_event_queue_pending_and_inflight_are_visible
        ; test_case "chat queue pending rows are visible" `Quick
            test_chat_queue_pending_rows_are_visible
        ; test_case "chat queue inflight priority matches structured projection" `Quick
            test_chat_queue_inflight_priority_matches_structured_projection
        ; test_case "recent chat failures are bounded newest first" `Quick
            test_recent_failed_chat_projection_is_bounded_and_newest_first
        ; test_case "turn admission waiting row is visible" `Quick
            test_turn_admission_waiting_row_is_visible
        ; test_case "turn admission shutdown row is deferred" `Quick
            test_turn_admission_shutdown_row_is_deferred
        ; test_case "keeper-owned schedule rows are lane scoped" `Quick
            test_keeper_owned_schedule_waiting_rows_are_lane_scoped
        ; test_case "live turn keeper is busy without waiting rows" `Quick
            test_live_turn_keeper_is_busy_without_waiting_rows
        ; test_case "corrupt schedule ledger is read_error" `Quick
            test_corrupt_schedule_ledger_is_read_error
        ; test_case "corrupt chat queue is read_error" `Quick
            test_corrupt_chat_queue_snapshot_is_read_error
        ; test_case "queue-only Keeper remains visible" `Quick
            test_queue_only_keeper_is_not_hidden_by_meta_inventory
        ; test_case "global queue config error remains visible" `Quick
            test_global_queue_configuration_error_without_meta_is_visible
        ; test_case "keeper name discovery failure is read_error" `Quick
            test_keeper_name_discovery_failure_is_read_error
        ; test_case "corrupt external attention is read_error" `Quick
            test_corrupt_external_attention_is_read_error
        ; test_case "external attention projection is bounded" `Quick
            test_external_attention_projection_is_bounded
        ; test_case "global pending confirm is actionable row" `Quick
            test_global_pending_confirm_is_actionable_row
        ; test_case "goal pending confirm id collision stays global" `Quick
            test_goal_pending_confirm_id_collision_stays_global
        ; test_case "corrupt pending confirms is read_error" `Quick
            test_corrupt_pending_confirms_is_read_error
        ] )
    ]
;;
