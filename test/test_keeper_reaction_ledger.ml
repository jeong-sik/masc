open Alcotest
open Masc
open Yojson.Safe.Util

let with_temp_base f =
  let base_path = Filename.temp_file "masc-krl-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  f base_path
;;

let board_payload ?updated_at ~post_id:(_ : string) () :
  Keeper_event_queue.stimulus_payload
  =
  Keeper_event_queue.Board_signal
    { kind = Keeper_event_queue.Post_created
    ; author = "operator"
    ; title = "Ship reaction ledger"
    ; content = "Please react"
    ; hearth = None
    ; updated_at
    }
;;

let board_stimulus ?(post_id = "post-42") ?updated_at () :
  Keeper_event_queue.stimulus
  =
  { post_id
  ; urgency = Immediate
  ; arrived_at = 1234.5
  ; payload = board_payload ?updated_at ~post_id ()
  }
;;

let fusion_completed_stimulus ?(run_id = "fus-ledger-1") () :
  Keeper_event_queue.stimulus
  =
  { post_id = "fusion-run:" ^ run_id
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 1234.5
  ; payload =
      Keeper_event_queue.Fusion_completed
        { run_id
        ; terminal = Keeper_event_queue.Fusion_succeeded "use approach B"
        ; board_post_id = "post-fus"
        ; channel = Keeper_continuation_channel.unrouted "test fixture"
        }
  }
;;

let schedule_due_stimulus ?(schedule_id = "sched-ledger-1") () :
  Keeper_event_queue.stimulus
  =
  { post_id = "schedule-due:" ^ schedule_id
  ; urgency = Keeper_event_queue.Immediate
  ; arrived_at = 1234.5
  ; payload =
      Keeper_event_queue.Schedule_due
        { occurrence_id = "schedule-due:" ^ schedule_id
        ; schedule_instance_id = "instance-" ^ schedule_id
        ; schedule_id
        ; due_at = 1200.0
        ; payload_digest = "payload-digest"
        ; title = Some "Wake"
        ; message = "Scheduled lane wake"
        ; result_delivery = None
        }
  }
;;


let require_ok label = function
  | Ok value -> value
  | Error message -> failf "%s: %s" label message
;;

let check_member_string label expected key json =
  check string label expected (json |> member key |> to_string)
;;

let check_list_has_string label expected json =
  check bool label true
    (json
     |> to_list
     |> List.exists (fun item -> String.equal expected (to_string item)))
;;

let rec mkdir_p path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)
;;

let event_queue_snapshot_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    "event-queue-v19.json"
;;

let reaction_ledger_dir ~base_path ~keeper_name =
  (* Ask the writer where it writes. Rebuilding the path here made a storage
     generation bump silently point the test at an empty old namespace. *)
  Masc.Keeper_reaction_ledger.store_dir
    ~masc_root:(Common.masc_dir_from_base_path ~base_path)
    ~keeper_name
;;

let reaction_ledger_store ~base_path ~keeper_name =
  Dated_jsonl.create
    ~base_dir:(reaction_ledger_dir ~base_path ~keeper_name)
    ()
;;

let read_recent_rows ~base_path ~keeper_name ~limit =
  match
    Dated_jsonl.read_recent_result
      (reaction_ledger_store ~base_path ~keeper_name)
      limit
  with
  | Error error -> fail (Dated_jsonl.read_error_to_string error)
  | Ok entries ->
    List.map
      (function
        | Dated_jsonl.Parsed row -> row
        | Dated_jsonl.Malformed_json { path; line_number; detail } ->
          failf
            "unexpected malformed test row %s%s: %s"
            path
            (match line_number with
             | Some value -> Printf.sprintf ":%d" value
             | None -> "")
            detail)
      entries
;;

let with_state_change_observer observer f =
  Keeper_reaction_ledger.install_state_change_observer observer;
  Fun.protect
    ~finally:(fun () -> Keeper_reaction_ledger.install_state_change_observer ignore)
    f
;;

let require_complete_evidence label = function
  | Error error ->
    failf
      "%s: %s"
      label
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
  | Ok (Keeper_reaction_ledger.Evidence_complete evidence) -> evidence
  | Ok (Keeper_reaction_ledger.Evidence_quarantined { first_reason; _ }) ->
    failf
      "%s: quarantined (%s)"
      label
      (Keeper_reaction_ledger.row_quarantine_reason_to_string first_reason)
;;

let latest_row rows =
  match List.rev rows with
  | row :: _ -> row
  | [] -> fail "expected at least one reaction ledger row"
;;

let test_event_queue_stimulus_and_turn_reaction () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "ledger-keeper" in
  let stimulus = board_stimulus () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Keeper_reaction_ledger.record_event_queue_turn_started
    ~base_path
    ~keeper_name
    stimulus;
  let rows =
    read_recent_rows ~base_path ~keeper_name ~limit:10
  in
  check int "two rows persisted" 2 (List.length rows);
  let stimulus_row = List.nth rows 0 in
  check_member_string "stimulus schema" Masc.Keeper_reaction_ledger.schema "schema" stimulus_row;
  check_member_string "stimulus record kind" "stimulus" "record_kind" stimulus_row;
  check_member_string "board stimulus id" "board:post-42" "stimulus_id" stimulus_row;
  check_member_string
    "stimulus kind"
    "board_signal"
    "kind"
    (stimulus_row |> member "stimulus");
  let reaction_row = List.nth rows 1 in
  check_member_string "reaction record kind" "reaction" "record_kind" reaction_row;
  check_member_string "reaction stimulus id" "board:post-42" "stimulus_id" reaction_row;
  check_member_string
    "reaction kind"
    "turn_started"
    "kind"
    (reaction_row |> member "reaction")
;;

(* A stimulus's evidence used to end at "a turn started at T", and what the turn
   did was recovered by comparing that clock against the keeper's calls. The
   closing row makes the interval and the outcome a record instead. *)
let test_turn_finished_closes_the_interval_the_start_opened () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "ledger-keeper" in
  let stimulus = board_stimulus ~post_id:"finish-post" () in
  Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name stimulus;
  Keeper_reaction_ledger.record_event_queue_turn_started ~base_path ~keeper_name stimulus;
  Keeper_reaction_ledger.record_event_queue_turn_finished
    ~base_path
    ~keeper_name
    ~disposition:"completed"
    stimulus;
  let rows = read_recent_rows ~base_path ~keeper_name ~limit:10 in
  check int "three rows persisted" 3 (List.length rows);
  let finished_row = List.nth rows 2 in
  check_member_string "reaction record kind" "reaction" "record_kind" finished_row;
  check_member_string
    "reaction kind"
    "turn_finished"
    "kind"
    (finished_row |> member "reaction");
  check_member_string
    "the turn's own outcome, not this writer's guess"
    "completed"
    "disposition"
    (finished_row |> member "reaction");
  (* Both halves name the same stimulus, which is what makes them an interval
     rather than two unrelated rows. *)
  check_member_string
    "same stimulus as the start"
    "board:finish-post"
    "stimulus_id"
    finished_row;
  check_member_string
    "and its own event identity"
    "board:finish-post:reaction:turn_finished"
    "event_id"
    finished_row
;;

let test_direct_append_state_change_observer_contract () =
  let notifications = ref 0 in
  with_state_change_observer
    (fun () -> incr notifications)
    (fun () ->
       with_temp_base @@ fun base_path ->
       let keeper_name = "observer-keeper" in
       let stimulus = board_stimulus ~post_id:"observer-post" () in
       Keeper_reaction_ledger.record_event_queue_stimulus
         ~base_path
         ~keeper_name
         stimulus;
       check int "successful stimulus append notifies" 1 !notifications;
       Keeper_reaction_ledger.record_event_queue_turn_started
         ~base_path
         ~keeper_name
         stimulus;
       check int "successful turn-start append notifies" 2 !notifications;
       let rows = read_recent_rows ~base_path ~keeper_name ~limit:10 in
       check int "both notified rows are durable" 2 (List.length rows));
  notifications := 0;
  with_state_change_observer
    (fun () -> incr notifications)
    (fun () ->
       with_temp_base @@ fun base_path ->
       let keeper_name = "append-failure-keeper" in
       let ledger_dir = reaction_ledger_dir ~base_path ~keeper_name in
       mkdir_p (Filename.dirname ledger_dir);
       write_file ledger_dir "not a directory";
       let append_failed =
         try
           Keeper_reaction_ledger.record_event_queue_stimulus
             ~base_path
             ~keeper_name
             (board_stimulus ~post_id:"append-failure" ());
           false
         with
         | _ -> true
       in
       check bool "ledger append fails" true append_failed;
       check int "failed append does not notify" 0 !notifications)
;;

let test_direct_append_observer_failure_is_isolated () =
  with_state_change_observer
    (fun () -> failwith "observer fault")
    (fun () ->
       with_temp_base @@ fun base_path ->
       let keeper_name = "observer-failure-keeper" in
       let stimulus = board_stimulus ~post_id:"observer-failure" () in
       Keeper_reaction_ledger.record_event_queue_stimulus
         ~base_path
         ~keeper_name
         stimulus;
       Keeper_reaction_ledger.record_event_queue_turn_started
         ~base_path
         ~keeper_name
         stimulus;
       let rows = read_recent_rows ~base_path ~keeper_name ~limit:10 in
       check int "observer failure preserves both durable rows" 2 (List.length rows))
;;


let test_current_rows_require_complete_writer_shape () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "closed-row-shape-keeper" in
  let stimulus = board_stimulus ~post_id:"closed-row" () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Keeper_reaction_ledger.record_event_queue_turn_started
    ~base_path
    ~keeper_name
    stimulus;
  let rows = read_recent_rows ~base_path ~keeper_name ~limit:2 in
  let remove_nested_field outer inner = function
    | `Assoc fields ->
      let nested =
        match List.assoc_opt outer fields with
        | Some (`Assoc nested_fields) ->
          `Assoc (List.remove_assoc inner nested_fields)
        | _ -> failf "missing nested object %s" outer
      in
      `Assoc ((outer, nested) :: List.remove_assoc outer fields)
    | _ -> fail "ledger writer did not emit an object"
  in
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name)
    (remove_nested_field "stimulus" "urgency" (List.nth rows 0));
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name)
    (remove_nested_field "reaction" "post_id" (List.nth rows 1));
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "incomplete current rows are quarantined" 2
    (summary |> member "quarantined_row_count" |> to_int);
  let reasons =
    summary
    |> member "quarantine_reason_counts"
    |> to_list
    |> List.map (fun item -> item |> member "reason" |> to_string)
  in
  check bool "missing stimulus urgency is typed" true
    (List.mem "missing_stimulus_urgency" reasons);
  check bool "missing reaction post id is typed" true
    (List.mem "missing_reaction_post_id" reasons)
;;

let test_unknown_record_kind_is_quarantined_not_fatal () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "unknown-record-kind-keeper" in
  let stimulus = board_stimulus ~post_id:"post-99" () in
  let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name)
    (`Assoc
        [ "schema", `String Masc.Keeper_reaction_ledger.schema
        ; "record_kind", `String "unexpected"
        ; "event_id", `String "krl:unknown-record-kind-fixture"
        ; "keeper_name", `String keeper_name
        ; "recorded_at_unix", `Float 5678.25
        ; "stimulus_id", `String stimulus_id
        ]);
  match
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id
  with
  | Error error ->
    failf
      "unknown record kind must not surface a fatal evidence read error: %s"
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
  | Ok (Keeper_reaction_ledger.Evidence_complete _) ->
    fail "unknown record kind must be quarantined, not silently accepted"
  | Ok
      (Keeper_reaction_ledger.Evidence_quarantined
        { evidence; first_reason }) ->
    check bool "normal stimulus row still matches" true evidence.stimulus_seen;
    check int "one row matches (the stimulus)" 1 evidence.matched_record_count;
    check int "unknown record kind is quarantined" 1
      evidence.quarantined_record_count;
    check string
      "quarantine reason is unknown record kind"
      "unknown_record_kind"
      (Keeper_reaction_ledger.row_quarantine_reason_to_string first_reason)
;;

let test_summary_marks_unreacted_and_reacted_stimuli () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "summary-keeper" in
  let stimulus = board_stimulus ~post_id:"post-summary" () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let pending_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "pending summary status" "degraded" "status" pending_summary;
  check bool "pending summary asks for operator visibility" true
    (pending_summary |> member "operator_action_required" |> to_bool);
  check int "pending stimulus count" 1
    (pending_summary |> member "pending_stimulus_count" |> to_int);
  check string "pending stimulus id" "board:post-summary"
    (pending_summary
     |> member "pending_stimulus_ids"
     |> to_list
     |> List.hd
     |> to_string);
  Keeper_reaction_ledger.record_event_queue_turn_started
    ~base_path
    ~keeper_name
    stimulus;
  let reacted_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "reacted summary status" "ok" "status" reacted_summary;
  check bool "reacted summary clears operator action" false
    (reacted_summary |> member "operator_action_required" |> to_bool);
  check int "reacted pending stimulus count" 0
    (reacted_summary |> member "pending_stimulus_count" |> to_int);
  check int "turn started count" 1
    (reacted_summary |> member "turn_started_count" |> to_int)
;;

(* The fleet verdict reads each keeper's typed status. It used to sum the
   pending and quarantined counts back out of the JSON those summaries had
   just been rendered into, with a string comparison behind it that nothing
   could reach (#27560). This is the path that carries a degraded keeper up
   with no durable-queue signal involved. *)
let test_fleet_summary_follows_a_degraded_keeper () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "fleet-degraded-keeper" in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    (board_stimulus ~post_id:"post-fleet-degraded" ());
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "the keeper itself is degraded" "degraded" "status" summary;
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check int
    "no stale durable queue, so that path cannot be what degrades the fleet"
    0
    (fleet |> member "durable_event_queue_stale_count" |> to_int);
  check_member_string
    "a degraded keeper degrades the fleet"
    "degraded"
    "status"
    fleet
;;

 let test_fleet_summary_surfaces_durable_event_queue_backlog () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "durable-backlog-keeper" in
  Keeper_registry_event_queue.enqueue
    ~base_path
    keeper_name
    (board_stimulus ~post_id:"post-live-backlog" ());
  Keeper_registry_event_queue.enqueue
    ~base_path
    keeper_name
    (board_stimulus ~post_id:"post-live-backlog-2" ());
  Keeper_registry_event_queue.enqueue
    ~base_path
    keeper_name
    (fusion_completed_stimulus ());
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check_member_string "durable queue backlog degrades fleet summary" "degraded" "status" fleet;
  check_list_has_string
    "durable queue stale reason is explicit"
    "durable_event_queue_stale"
    (fleet |> member "status_reasons");
  check bool "durable queue backlog requires operator action" true
    (fleet |> member "operator_action_required" |> to_bool);
  check int "ledger pending rows stay independent" 0
    (fleet |> member "pending_stimulus_count" |> to_int);
  check int "durable queue backlog counted" 3
    (fleet |> member "durable_event_queue_count" |> to_int);
  check int "durable queue pending backlog counted" 3
    (fleet |> member "durable_event_queue_pending_count" |> to_int);
  check (float 0.001) "default durable queue stale threshold preserves prior behavior"
    0.0
    (fleet |> member "durable_event_queue_stale_after_sec" |> to_float);
  check int "durable queue stale backlog counted" 3
    (fleet |> member "durable_event_queue_stale_count" |> to_int);
  check int "durable queue stale keeper counted" 1
    (fleet |> member "durable_event_queue_stale_keeper_count" |> to_int);
  let keeper_queue =
    fleet |> member "durable_event_queue_by_keeper" |> to_list |> List.hd
  in
  check_member_string
    "durable queue keeper name"
    keeper_name
    "keeper_name"
    keeper_queue;
  check int "keeper durable queue backlog counted" 3
    (keeper_queue |> member "durable_event_queue_count" |> to_int);
  check int "keeper durable queue pending backlog counted" 3
    (keeper_queue |> member "durable_event_queue_pending_count" |> to_int);
  check int "keeper immediate durable queue backlog counted" 2
    (keeper_queue |> member "immediate_count" |> to_int);
  check bool "keeper durable queue is stale by default" true
    (keeper_queue |> member "stale" |> to_bool);
  check int "stale keeper list mirrors stale backlog" 1
    (fleet |> member "durable_event_queue_stale_by_keeper" |> to_list |> List.length);
  let payload_counts =
    fleet |> member "durable_event_queue_payload_counts" |> to_list
  in
  check bool "board_signal durable payload count is surfaced" true
    (List.exists
       (fun json ->
         String.equal (json |> member "payload_kind" |> to_string) "board_signal"
         && json |> member "count" |> to_int = 2)
       payload_counts);
  check bool "fusion_completed durable payload count is surfaced" true
    (List.exists
       (fun json ->
         String.equal (json |> member "payload_kind" |> to_string) "fusion_completed"
         && json |> member "count" |> to_int = 1)
       payload_counts)
;;

let test_fleet_summary_discovers_durable_event_queue_backlog_without_meta_name () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "durable-only-keeper" in
  Keeper_registry_event_queue.enqueue
    ~base_path
    keeper_name
    (board_stimulus ~post_id:"post-durable-only" ());
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[]
      ~limit_per_keeper:10
  in
  check_member_string
    "durable-only queue degrades fleet summary"
    "degraded"
    "status"
    fleet;
  check int "durable-only keeper is included in fleet count" 1
    (fleet |> member "keeper_count" |> to_int);
  check_list_has_string
    "durable-only keeper name is discovered"
    keeper_name
    (fleet |> member "keeper_names");
  check int "durable-only discovery counted" 1
    (fleet |> member "durable_event_queue_discovered_keeper_count" |> to_int);
  check_list_has_string
    "durable-only discovery names keeper"
    keeper_name
    (fleet |> member "durable_event_queue_discovered_keeper_names");
  check bool "durable-only discovery has no read error" true
    (match fleet |> member "durable_event_queue_discovery_error" with
     | `Null -> true
     | _ -> false);
  check int "durable-only queue backlog counted" 1
    (fleet |> member "durable_event_queue_count" |> to_int);
  let keeper_queue =
    fleet |> member "durable_event_queue_by_keeper" |> to_list |> List.hd
  in
  check_member_string
    "durable-only queue keeper name"
    keeper_name
    "keeper_name"
    keeper_queue;
  check int "durable-only keeper queue backlog counted" 1
    (keeper_queue |> member "durable_event_queue_count" |> to_int)
;;

let test_fleet_summary_surfaces_durable_event_queue_discovery_error () =
  with_temp_base @@ fun base_path ->
  let invalid_keeper_name = "invalid keeper name" in
  let invalid_keeper_dir =
    Filename.concat
      (Common.keepers_runtime_dir_of_base ~base_path)
      invalid_keeper_name
  in
  mkdir_p invalid_keeper_dir;
  write_file
    (Filename.concat invalid_keeper_dir "event-queue-v19.json")
    (Yojson.Safe.to_string (Keeper_event_queue.queue_to_yojson Keeper_event_queue.empty));
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[]
      ~limit_per_keeper:10
  in
  check_member_string
    "durable queue discovery error makes fleet status unknown"
    "unknown"
    "status"
    fleet;
  check_list_has_string
    "durable queue discovery error reason is explicit"
    "durable_event_queue_discovery_error"
    (fleet |> member "status_reasons");
  check bool "durable queue discovery error requires operator action" true
    (fleet |> member "operator_action_required" |> to_bool);
  check int "durable queue discovery error counted" 1
    (fleet |> member "durable_event_queue_discovery_error_count" |> to_int);
  check bool "durable queue discovery error message is surfaced" true
    (match fleet |> member "durable_event_queue_discovery_error" with
     | `String value -> not (String.equal value "")
     | _ -> false);
  check int "invalid durable queue keeper is not accepted as a keeper" 0
    (fleet |> member "keeper_count" |> to_int)
;;

let test_fleet_summary_allows_nonstale_durable_event_queue_backlog () =
  if Sys.getenv_opt "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC" <> None then
    skip ()
  else
  Fun.protect
    ~finally:(fun () -> Config_boot_overrides.reset_for_tests ())
    (fun () ->
       Config_boot_overrides.reset_for_tests ();
       Config_boot_overrides.set "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC" "1000000000000.0";
       with_temp_base @@ fun base_path ->
       let keeper_name = "fresh-durable-backlog-keeper" in
       Keeper_registry_event_queue.enqueue
         ~base_path
         keeper_name
         (board_stimulus ~post_id:"post-fresh-backlog" ());
       let fleet =
         Keeper_reaction_ledger.fleet_summary_json
           ~base_path
           ~keeper_names:[ keeper_name ]
           ~limit_per_keeper:10
       in
       check_member_string
         "fresh durable backlog remains visible but not degraded"
         "ok"
         "status"
         fleet;
       check bool "fresh durable backlog does not require operator action" false
         (fleet |> member "operator_action_required" |> to_bool);
       check int "fresh durable queue backlog counted" 1
         (fleet |> member "durable_event_queue_count" |> to_int);
       check int "fresh durable queue stale count stays zero" 0
         (fleet |> member "durable_event_queue_stale_count" |> to_int);
       check int "fresh durable queue stale keeper count stays zero" 0
         (fleet |> member "durable_event_queue_stale_keeper_count" |> to_int);
       check (float 0.001) "durable stale threshold comes from boot override"
         1000000000000.0
         (fleet |> member "durable_event_queue_stale_after_sec" |> to_float);
       let keeper_queue =
         fleet |> member "durable_event_queue_by_keeper" |> to_list |> List.hd
       in
       check bool "fresh durable queue is not stale" false
         (keeper_queue |> member "stale" |> to_bool);
       check int "fresh durable stale keeper list is empty" 0
         (fleet |> member "durable_event_queue_stale_by_keeper" |> to_list |> List.length))
;;

let test_fleet_summary_surfaces_durable_event_queue_read_error () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "broken-durable-queue-keeper" in
  let path = event_queue_snapshot_path ~base_path ~keeper_name in
  mkdir_p (Filename.dirname path);
  write_file path "{not-json";
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check_member_string
    "durable queue read error makes fleet status unknown"
    "unknown"
    "status"
    fleet;
  check_list_has_string
    "durable queue read error reason is explicit"
    "durable_event_queue_read_error"
    (fleet |> member "status_reasons");
  check bool "durable queue read error requires operator action" true
    (fleet |> member "operator_action_required" |> to_bool);
  check int "durable queue read error counted" 1
    (fleet |> member "durable_event_queue_read_error_count" |> to_int);
  let keeper_error =
    fleet |> member "durable_event_queue_read_errors_by_keeper" |> to_list |> List.hd
  in
  check_member_string
    "durable queue read error keeper name"
    keeper_name
    "keeper_name"
    keeper_error;
  check int "keeper durable queue read error counted" 1
    (keeper_error |> member "read_error_count" |> to_int);
  let read_error =
    keeper_error |> member "read_errors" |> to_list |> List.hd
  in
  check_member_string
    "durable queue read error kind"
    "read_failed"
    "kind"
    read_error;
  check_member_string "durable queue read error path" path "path" read_error
;;

let test_fleet_summary_surfaces_durable_event_queue_parse_error () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "parse-broken-durable-queue-keeper" in
  let path = event_queue_snapshot_path ~base_path ~keeper_name in
  mkdir_p (Filename.dirname path);
  write_file path {|{"schema":"unexpected.event.queue.schema","items":{}}|};
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check_member_string
    "durable queue parse error makes fleet status unknown"
    "unknown"
    "status"
    fleet;
  check_list_has_string
    "durable queue parse error reason is explicit"
    "durable_event_queue_read_error"
    (fleet |> member "status_reasons");
  check bool "durable queue parse error requires operator action" true
    (fleet |> member "operator_action_required" |> to_bool);
  check int "durable queue parse error counted" 1
    (fleet |> member "durable_event_queue_read_error_count" |> to_int);
  let keeper_error =
    fleet |> member "durable_event_queue_read_errors_by_keeper" |> to_list |> List.hd
  in
  check_member_string
    "durable queue parse error keeper name"
    keeper_name
    "keeper_name"
    keeper_error;
  check int "keeper durable queue parse error counted" 1
    (keeper_error |> member "read_error_count" |> to_int);
  let read_error =
    keeper_error |> member "read_errors" |> to_list |> List.hd
  in
  check_member_string
    "durable queue parse error kind"
    "parse_failed"
    "kind"
    read_error;
  check_member_string "durable queue parse error path" path "path" read_error
;;

let test_lock_free_observation_rejects_generation_change () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "observation-generation-change" in
  let first = schedule_due_stimulus ~schedule_id:"before-observation" () in
  let second = schedule_due_stimulus ~schedule_id:"during-observation" () in
  (match
     Keeper_event_queue_persistence.enqueue_stimulus_if_absent_result
       ~base_path
       ~keeper_name
       first
   with
   | Ok _ -> ()
   | Error error -> failf "failed to seed durable event queue: %s" error);
  let observed =
    Keeper_event_queue_persistence.For_testing
    .observe_snapshot_with_errors_with_interleave
      ~between_samples:(fun () ->
        match
          Keeper_event_queue_persistence.enqueue_stimulus_if_absent_result
            ~base_path
            ~keeper_name
            second
        with
        | Ok _ -> ()
        | Error error -> failf "failed to mutate durable event queue: %s" error)
      ~base_path
      ~keeper_name
  in
  check int
    "incoherent observation returns exactly one typed error"
    1
    (List.length observed.read_errors);
  let error = List.hd observed.read_errors in
  check string
    "concurrent generation change is typed unavailable"
    "incoherent_read"
    (Keeper_event_queue_persistence.snapshot_read_error_kind_to_string error.kind);
  check int
    "incoherent observation cannot return a healthy queue"
    0
    (Keeper_event_queue.length observed.pending)
;;

let test_unknown_reaction_is_quarantined_without_clearing_pending () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "unknown-reaction-keeper" in
  let stimulus = board_stimulus ~post_id:"post-unknown-reaction" () in
  let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name)
    (`Assoc
        [ "schema", `String Masc.Keeper_reaction_ledger.schema
        ; "record_kind", `String "reaction"
        ; "event_id", `String (stimulus_id ^ ":reaction:turn_started")
        ; "keeper_name", `String keeper_name
        ; "recorded_at_unix", `Float 1235.0
        ; "stimulus_id", `String stimulus_id
        ; ( "reaction"
          , `Assoc
              [ "kind", `String "unknown_custom"
              ; "source", `String "keeper_event_queue"
              ] )
        ]);
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "unknown reaction summary status" "degraded" "status" summary;
  check bool "unknown reaction requires operator action" true
    (summary |> member "operator_action_required" |> to_bool);
  check int "unknown reaction quarantined" 1
    (summary |> member "quarantined_row_count" |> to_int);
  check int "unknown reaction contributes no current reaction" 0
    (summary |> member "reaction_count" |> to_int);
  check int "unknown reaction cannot clear pending" 1
    (summary |> member "pending_stimulus_count" |> to_int);
  match
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id
  with
  | Ok
      (Keeper_reaction_ledger.Evidence_quarantined
        { evidence; first_reason }) ->
    check int "only current stimulus matches" 1 evidence.matched_record_count;
    check int "matching invalid row is explicit" 1 evidence.quarantined_record_count;
    check bool "invalid reaction is not a turn" false evidence.turn_started_seen;
    check string
      "typed quarantine reason"
      "unknown_reaction_kind"
      (Keeper_reaction_ledger.row_quarantine_reason_to_string first_reason)
  | Error error ->
    fail
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
  | Ok (Keeper_reaction_ledger.Evidence_complete _) ->
    fail "matching invalid row was projected as complete evidence"
;;

(* RFC-0020: the stimulus payload is a typed closed variant, so a malformed
   payload is unrepresentable — the prior [test_malformed_typed_payload_degrades_summary]
   covered a parse-error path that can no longer occur and was removed. *)

(* RFC-0266 regression: a recorded [Fusion_completed] stimulus is a recognized
   closed-sum kind and must NOT be miscounted as an unsupported stimulus.  The
   prior string whitelist
   dropped [fusion_completed] into [unsupported_stimulus_count], degrading the
   summary on every async fusion wake.  (We assert only the unsupported counter:
   with no reaction row the stimulus is still legitimately pending.) *)
let test_fusion_completed_stimulus_is_supported () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "fusion-keeper" in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    (fusion_completed_stimulus ());
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "fusion_completed survives the closed row decoder" 0
    (summary |> member "quarantined_row_count" |> to_int)
;;

(* Drift guard: [stimulus_kind_of_string] must stay the inverse of
   [stimulus_kind_to_string] for every closed-sum variant, and reject unknowns.
   Pairs with the exhaustive match in [note_stimulus_kind] so a new variant
   cannot silently fall back to [unsupported]. *)
let test_stimulus_kind_string_roundtrip () =
  let roundtrips k =
    match
      Keeper_reaction_ledger.stimulus_kind_of_string
        (Keeper_reaction_ledger.stimulus_kind_to_string k)
    with
    | Some k' ->
      String.equal
        (Keeper_reaction_ledger.stimulus_kind_to_string k')
        (Keeper_reaction_ledger.stimulus_kind_to_string k)
    | None -> false
  in
  List.iter
    (fun k ->
      check bool "stimulus_kind round-trips through string" true (roundtrips k))
    [ Keeper_reaction_ledger.Board_signal
    ; Keeper_reaction_ledger.Bootstrap
    ; Keeper_reaction_ledger.Fusion_completed
    ; Keeper_reaction_ledger.Schedule_due
    ; Keeper_reaction_ledger.Connector_attention
    ; Keeper_reaction_ledger.Hitl_resolved
    ; Keeper_reaction_ledger.Completion_authority_rejected
    ];
  check bool "unknown stimulus kind string is None" true
    (Option.is_none (Keeper_reaction_ledger.stimulus_kind_of_string "totally_unknown"))
;;

(* Drift guard: known reaction labels round-trip through the closed decoder;
   unknown labels remain typed failures and never enter the reaction algebra. *)
let test_reaction_kind_string_roundtrip () =
  let roundtrips k =
    match
      Keeper_reaction_ledger.reaction_kind_of_string
        (Keeper_reaction_ledger.reaction_kind_to_string k)
    with
    | Ok parsed ->
      String.equal
        (Keeper_reaction_ledger.reaction_kind_to_string parsed)
        (Keeper_reaction_ledger.reaction_kind_to_string k)
    | Error _ -> false
  in
  List.iter
    (fun k ->
      check bool "reaction_kind round-trips through string" true (roundtrips k))
    [ Keeper_reaction_ledger.Turn_started
    ; Keeper_reaction_ledger.Event_queue_ack
    ; Keeper_reaction_ledger.Event_queue_cancelled
    ];
  match Keeper_reaction_ledger.reaction_kind_of_string "unknown_custom" with
  | Error (Keeper_reaction_ledger.Unknown_reaction_kind value) ->
    check string "unknown reaction decoder preserves evidence" "unknown_custom" value
  | Ok _ -> fail "unknown reaction string must not decode"
;;

let test_unexpected_schema_rows_are_quarantined_without_double_counting () =
  with_temp_base
  @@ fun base_path ->
  let keeper_name = "alpha" in
  let stimulus = board_stimulus () in
  let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let current_event_id =
    read_recent_rows ~base_path ~keeper_name ~limit:1
    |> latest_row
    |> member "event_id"
    |> to_string
  in
  let store = reaction_ledger_store ~base_path ~keeper_name in
  Dated_jsonl.append
    store
    (`Assoc
        [ "schema", `String "keeper.reaction_ledger.foreign"
        ; "record_kind", `String "stimulus"
        ; "event_id", `String current_event_id
        ; "keeper_name", `String keeper_name
        ; "recorded_at_unix", `Float 1200.0
        ; "stimulus_id", `String stimulus_id
        ; ( "stimulus"
          , `Assoc
              [ "kind", `String "board_signal"
              ; "source", `String "keeper_event_queue"
              ; "post_id", `String stimulus.post_id
              ] )
        ]);
  Dated_jsonl.append
    store
    (`Assoc
        [ "schema", `String "keeper.reaction_ledger.foreign"
        ; "record_kind", `String "reaction"
        ; "event_id", `String (stimulus_id ^ ":reaction:turn_started")
        ; "keeper_name", `String keeper_name
        ; "recorded_at_unix", `Float 1201.0
        ; "stimulus_id", `String stimulus_id
        ; ( "reaction"
          , `Assoc
              [ "kind", `String "turn_started"
              ; "source", `String "keeper_event_queue"
              ] )
        ]);
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check
    int
    "only the current generation contributes"
    1
    (summary |> member "stimulus_count" |> to_int);
  check int "unexpected reaction contributes zero" 0
    (summary |> member "reaction_count" |> to_int);
  check int "unexpected reaction cannot clear current pending" 1
    (summary |> member "pending_stimulus_count" |> to_int);
  check
    int
    "both unexpected rows are quarantined"
    2
    (summary |> member "quarantined_row_count" |> to_int);
  let unexpected_reason =
    summary |> member "quarantine_reason_counts" |> to_list |> List.hd
  in
  check_member_string
    "unexpected schema reason is typed"
    "unexpected_schema"
    "reason"
    unexpected_reason;
  check int "unexpected schema reason count" 2
    (unexpected_reason |> member "count" |> to_int);
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check int "fleet exposes quarantined rows" 2
    (fleet |> member "quarantined_row_count" |> to_int);
  check_list_has_string
    "fleet status names quarantine"
    "reaction_ledger_quarantined_row"
    (fleet |> member "status_reasons")
;;

let test_quarantine_is_keeper_local () =
  with_temp_base
  @@ fun base_path ->
  let quarantined_keeper = "quarantined-keeper" in
  let healthy_keeper = "healthy-keeper" in
  let quarantined_stimulus = board_stimulus ~post_id:"post-quarantined" () in
  let quarantined_stimulus_id =
    Keeper_reaction_ledger.stimulus_id_of_event_queue quarantined_stimulus
  in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name:quarantined_keeper
    quarantined_stimulus;
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name:quarantined_keeper)
    (`Assoc
        [ "schema", `String "keeper.reaction_ledger.v2"
        ; "record_kind", `String "reaction"
        ; ( "event_id"
          , `String (quarantined_stimulus_id ^ ":reaction:turn_started") )
        ; "keeper_name", `String quarantined_keeper
        ; "recorded_at_unix", `Float 1201.0
        ; "stimulus_id", `String quarantined_stimulus_id
        ; ( "reaction"
          , `Assoc
              [ "kind", `String "turn_started"
              ; "source", `String "keeper_event_queue"
              ] )
        ]);
  let healthy_stimulus = board_stimulus ~post_id:"post-healthy" () in
  let healthy_stimulus_id =
    Keeper_reaction_ledger.stimulus_id_of_event_queue healthy_stimulus
  in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name:healthy_keeper
    healthy_stimulus;
  Keeper_reaction_ledger.record_event_queue_turn_started
    ~base_path
    ~keeper_name:healthy_keeper
    healthy_stimulus;
  (match
     Keeper_reaction_ledger.event_queue_reaction_evidence_result
       ~base_path
       ~keeper_name:healthy_keeper
       ~stimulus_id:healthy_stimulus_id
   with
   | Ok (Keeper_reaction_ledger.Evidence_complete evidence) ->
     check bool "healthy keeper turn remains visible" true evidence.turn_started_seen;
     check int "healthy keeper has no quarantine" 0 evidence.quarantined_record_count
   | Ok (Keeper_reaction_ledger.Evidence_quarantined _) ->
     fail "quarantine leaked across keeper stores"
   | Error error ->
     fail
       ("healthy keeper read failed: "
        ^ Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
            error));
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ quarantined_keeper; healthy_keeper ]
      ~limit_per_keeper:10
  in
  let healthy_summary =
    fleet
    |> member "keepers"
    |> to_list
    |> List.find (fun summary ->
      String.equal (summary |> member "keeper_name" |> to_string) healthy_keeper)
  in
  check_member_string "healthy keeper summary stays ok" "ok" "status" healthy_summary;
  check int "healthy keeper pending stays cleared" 0
    (healthy_summary |> member "pending_stimulus_count" |> to_int);
  check int "healthy keeper current reaction is preserved" 1
    (healthy_summary |> member "reaction_count" |> to_int)
;;

let test_syntax_error_does_not_claim_an_occurrence_identity () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "strict-evidence-keeper" in
  let ledger_dir = reaction_ledger_dir ~base_path ~keeper_name in
  let malformed_month = Filename.concat ledger_dir "2026-01" in
  mkdir_p malformed_month;
  let malformed_path = Filename.concat malformed_month "01.jsonl" in
  write_file malformed_path "not-json\n";
  let evidence =
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id:"schedule:test-occurrence"
    |> require_complete_evidence "unattributed syntax row"
  in
  check int "no row is assigned to the queried occurrence" 0
    evidence.matched_record_count;
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "malformed summary row is quarantined" 1
    (summary |> member "quarantined_row_count" |> to_int);
  let reason = summary |> member "quarantine_reason_counts" |> to_list |> List.hd in
  check_member_string "syntax quarantine reason" "malformed_json" "reason" reason
;;

let test_missing_identity_does_not_claim_an_occurrence_identity () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "identity-incomplete-keeper" in
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name)
    (`Assoc
        [ "schema", `String Masc.Keeper_reaction_ledger.schema
        ; "record_kind", `String "stimulus"
        ; "event_id", `String "unattributed-event"
        ; "keeper_name", `String keeper_name
        ; "recorded_at_unix", `Float 1234.0
        ; ( "stimulus"
          , `Assoc
              [ "kind", `String "schedule_due"
              ; "source", `String "keeper_event_queue"
              ] )
        ]);
  let evidence =
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id:"schedule:test-occurrence"
    |> require_complete_evidence "identity-less row"
  in
  check int "identity-less row is not assigned to the query" 0
    evidence.matched_record_count;
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "identity-less row remains operator-visible" 1
    (summary |> member "quarantined_row_count" |> to_int);
  let reason = summary |> member "quarantine_reason_counts" |> to_list |> List.hd in
  check_member_string "identity quarantine reason" "missing_stimulus_id" "reason" reason
;;

let test_event_queue_reaction_evidence_batch_indexes_multiple_occurrences () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "batch-evidence-keeper" in
  let first = schedule_due_stimulus ~schedule_id:"batch-first" () in
  let second = schedule_due_stimulus ~schedule_id:"batch-second" () in
  let first_id = Keeper_reaction_ledger.stimulus_id_of_event_queue first in
  let second_id = Keeper_reaction_ledger.stimulus_id_of_event_queue second in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    first;
  Keeper_reaction_ledger.record_event_queue_turn_started
    ~base_path
    ~keeper_name
    first;
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    second;
  let batch =
    match
      Keeper_reaction_ledger.event_queue_reaction_evidence_batch_result
        ~base_path
        ~keeper_name
        ~stimulus_ids:[ second_id; first_id; second_id ]
    with
    | Ok batch -> batch
    | Error error ->
      fail
        (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
           error)
  in
  check (list string) "first-request order with duplicates collapsed"
    [ second_id; first_id ]
    (List.map fst batch);
  let complete stimulus_id =
    match List.assoc_opt stimulus_id batch with
    | Some (Keeper_reaction_ledger.Evidence_complete evidence) -> evidence
    | Some (Keeper_reaction_ledger.Evidence_quarantined _) ->
      fail "batch evidence unexpectedly quarantined"
    | None -> fail "requested batch evidence is missing"
  in
  let second_evidence = complete second_id in
  check bool "second stimulus is visible" true second_evidence.stimulus_seen;
  check bool "second turn has not started" false second_evidence.turn_started_seen;
  check int "second has one exact row" 1 second_evidence.matched_record_count;
  let first_evidence = complete first_id in
  check bool "first stimulus is visible" true first_evidence.stimulus_seen;
  check bool "first turn start is visible" true first_evidence.turn_started_seen;
  check int "first has two exact rows" 2 first_evidence.matched_record_count;
  match
    Keeper_reaction_ledger.event_queue_reaction_evidence_batch_result
      ~base_path
      ~keeper_name
      ~stimulus_ids:[ "" ]
  with
  | Error Keeper_reaction_ledger.Evidence_invalid_stimulus_id -> ()
  | Error error ->
    failf
      "empty batch identity returned the wrong error: %s"
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
         error)
  | Ok _ -> fail "empty batch identity was accepted"
;;


(* The post-append fault seam is declared in the .mli as a boundary contract:
   it must exist exactly once as a definition and once as a declaration, so the
   fault path cannot acquire a second entry point.
   [scripts/keeper_event_queue_projection_boundary_check.ml] asserts that shape
   from outside the compiler, which is why an unused-declaration sweep read the
   declaration as dead and removed it (#27230), turning main red.

   This case holds the declaration from inside the compiler. It calls the seam
   with a callback that does nothing but record that it ran, so removing the
   declaration again is a compile error here rather than a red main later. *)
let test_after_ledger_append_seam_is_reachable_through_the_interface () =
  let ran = ref false in
  let result =
    Keeper_reaction_ledger.For_testing.with_after_ledger_append
      ~after_ledger_append:(fun () ->
        ran := true;
        Ok ())
      (fun () -> "body ran")
  in
  check string "the scoped body's value is returned" "body ran" result;
  (* The seam installs the hook for the scope; whether this body triggers an
     append is not this case's claim. What is claimed is that the declaration
     exists and its type is the one the boundary check names. *)
  ignore !ran
;;

(* The event id is recomputed on read and compared, so the digest decides
   replay: two stimuli landing on one id make the second read as the first.
   MD5 and SHA-256 both produce a hex string of the right shape, and every
   other case in this file passes under either, so the algorithm needs saying
   out loud (#26720). *)
let test_event_id_digest_is_sha256 () =
  let stimulus_id = "board:post-42" in
  let expected =
    "krl:" ^ Digestif.SHA256.(digest_string (stimulus_id ^ "|stimulus") |> to_hex)
  in
  let actual = Masc.Keeper_reaction_ledger.digest_id "krl" (stimulus_id ^ "|stimulus") in
  check string "event id carries a SHA-256 digest" expected actual;
  check
    int
    "and the full digest, not a truncation"
    (String.length "krl:" + 64)
    (String.length actual)
;;

(* The fleet summary emitted four statuses from a closed type and a fifth,
   "unavailable", as a bare string beside it, so nothing in the code said the
   vocabulary was five wide (#27560). These read the field the HTTP route
   serves and check it against the exported list. *)
let test_fleet_summary_status_vocabulary_is_closed () =
  let status json =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "status" fields with
       | Some (`String value) -> value
       | _ -> Alcotest.fail "fleet summary carried no status string")
    | _ -> Alcotest.fail "fleet summary is not an object"
  in
  let unavailable = status (Masc.Keeper_reaction_ledger.unavailable_fleet_summary_json ()) in
  Alcotest.(check bool)
    (Printf.sprintf "%S is in the declared vocabulary" unavailable)
    true
    (List.mem unavailable Masc.Keeper_reaction_ledger.fleet_summary_status_strings);
  Alcotest.(check (list string))
    "the vocabulary is exactly these five"
    [ "empty"; "ok"; "degraded"; "unknown"; "unavailable" ]
    Masc.Keeper_reaction_ledger.fleet_summary_status_strings
;;

let () =
  run
    "keeper_reaction_ledger"
    [ ( "ledger"
      , [ test_case
            "event queue stimulus and turn reaction are durable"
            `Quick
            test_event_queue_stimulus_and_turn_reaction
        ; test_case
            "turn finished closes the interval the start opened"
            `Quick
            test_turn_finished_closes_the_interval_the_start_opened
        ; test_case
            "unexpected schema rows cannot double-count current occurrences"
            `Quick
            test_unexpected_schema_rows_are_quarantined_without_double_counting
        ; test_case
            "direct append observer follows persistence"
            `Quick
            test_direct_append_state_change_observer_contract
        ; test_case
            "direct append observer failure is isolated"
            `Quick
            test_direct_append_observer_failure_is_isolated
        ; test_case
            "quarantine remains keeper-local"
            `Quick
            test_quarantine_is_keeper_local
        ; test_case
            "syntax error cannot claim an occurrence identity"
            `Quick
            test_syntax_error_does_not_claim_an_occurrence_identity
        ; test_case
            "missing identity cannot claim an occurrence identity"
            `Quick
            test_missing_identity_does_not_claim_an_occurrence_identity
        ; test_case
            "current rows require complete writer shape"
            `Quick
            test_current_rows_require_complete_writer_shape
        ; test_case
            "unknown record kind is quarantined, not fatal"
            `Quick
            test_unknown_record_kind_is_quarantined_not_fatal
        ; test_case
            "summary marks unreacted and reacted stimuli"
            `Quick
            test_summary_marks_unreacted_and_reacted_stimuli
        ; test_case
            "fleet summary follows a degraded keeper"
            `Quick
            test_fleet_summary_follows_a_degraded_keeper
        ; test_case
            "fleet summary surfaces durable event queue backlog"
            `Quick
            test_fleet_summary_surfaces_durable_event_queue_backlog
        ; test_case
            "fleet summary discovers durable event queue backlog without meta name"
            `Quick
            test_fleet_summary_discovers_durable_event_queue_backlog_without_meta_name
        ; test_case
            "fleet summary surfaces durable event queue discovery errors"
            `Quick
            test_fleet_summary_surfaces_durable_event_queue_discovery_error
        ; test_case
            "fleet summary separates fresh durable event queue backlog from stale"
            `Quick
            test_fleet_summary_allows_nonstale_durable_event_queue_backlog
        ; test_case
            "fleet summary surfaces durable event queue read errors"
            `Quick
            test_fleet_summary_surfaces_durable_event_queue_read_error
        ; test_case
            "fleet summary surfaces durable event queue parse errors"
            `Quick
            test_fleet_summary_surfaces_durable_event_queue_parse_error
        ; test_case
            "lock-free observation rejects generation change"
            `Quick
            test_lock_free_observation_rejects_generation_change
        ; test_case
            "unknown reaction is quarantined without clearing pending"
            `Quick
            test_unknown_reaction_is_quarantined_without_clearing_pending
        ; test_case
            "fusion_completed stimulus is supported (RFC-0266)"
            `Quick
            test_fusion_completed_stimulus_is_supported
        ; test_case
            "stimulus_kind string round-trip drift guard"
            `Quick
            test_stimulus_kind_string_roundtrip
        ; test_case
            "reaction_kind string round-trip drift guard"
            `Quick
            test_reaction_kind_string_roundtrip
        ; test_case
            "reaction evidence batch indexes multiple occurrences"
            `Quick
            test_event_queue_reaction_evidence_batch_indexes_multiple_occurrences
        ; test_case
            "after_ledger_append seam is reachable through the interface"
            `Quick
            test_after_ledger_append_seam_is_reachable_through_the_interface
        ; test_case
            "event id digest is SHA-256"
            `Quick
            test_event_id_digest_is_sha256
        ; test_case
            "fleet summary status vocabulary is closed"
            `Quick
            test_fleet_summary_status_vocabulary_is_closed
        ] )
    ]
;;
