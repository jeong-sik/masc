open Alcotest

module Bulk = Server_dashboard_http_keeper_event_queue_bulk
module Keeper_owner_registry = Masc.Keeper_owner_registry
module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence

let require_ok = function Ok value -> value | Error detail -> fail detail
let require_error = function Error _ -> () | Ok _ -> fail "request unexpectedly accepted"

let rm_rf = Fs_compat.remove_tree
let mkdir_p path = Fs_compat.mkdir_p path
let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)
;;

let row ?(source_ref = String.make 64 'a') ?(source_incarnation = 1L)
      ~keeper ~source ~since () : Bulk.row =
  { keeper_name = keeper; source_ref; source_incarnation; source_label = source
  ; source_arrived_at = since -. 100.0; first_admitted_at = Some since }
;;

let rows () =
  [ row ~keeper:"alpha" ~source:"board_signal" ~since:100.0 ()
  ; row ~source_ref:(String.make 64 'b') ~keeper:"alpha" ~source:"schedule_due" ~since:90.0 ()
  ; row ~keeper:"beta" ~source:"board_signal" ~since:80.0 () ]
;;

let selection (row : Bulk.row) : Bulk.selection =
  { keeper_name = row.keeper_name; source_ref = row.source_ref
  ; source_incarnation = row.source_incarnation }
;;

let no_filter : Bulk.filter = { keepers = None; sources = None }
let preview filter =
  Yojson.Safe.to_string (`Assoc [ "schema", `String Bulk.schema
                               ; "action", `String "preview"; "filter", filter ])
;;

let test_preview () =
  match require_ok (Bulk.parse (preview (`Assoc []))) with
  | Bulk.Preview filter -> check (option (list string)) "all keepers" None filter.keepers
  | Bulk.Cancel _ -> fail "preview became a mutation"
;;

let cancel_body selections =
  Yojson.Safe.to_string (`Assoc
    [ "schema", `String Bulk.schema; "action", `String "cancel"
    ; "reason", `String "operator disposition"; "filter", `Assoc []
    ; "selections", `List selections ])
;;

let selection_json incarnation =
  `Assoc [ "keeper_name", `String "alpha"; "source_ref", `String (String.make 64 'a')
         ; "source_incarnation", `String incarnation ]
;;

let test_int64_selection () =
  match require_ok (Bulk.parse (cancel_body [ selection_json "9007199254740993" ])) with
  | Bulk.Cancel { selections = [ selected ]; _ } ->
    check int64 "no JavaScript rounding" 9007199254740993L selected.source_incarnation
  | Bulk.Cancel _ | Bulk.Preview _ -> fail "wrong exact selection"
;;

let test_reject_ambiguous_requests () =
  List.iter (fun body -> Bulk.parse body |> require_error)
    [ {|{"schema":"keeper_event_queue.bulk.request.v1","action":"cancel","dry_run":false,"confirm":"cancel-pending-events","reason":"x"}|}
    ; preview (`Assoc [ "keeper", `List [ `String "alpha" ] ])
    ; preview (`Assoc [ "keepers", `List []; "keepers", `List [ `String "alpha" ] ])
    ; {|{"schema":"keeper_event_queue.bulk.request.v2","action":"preview","action":"cancel","filter":{}}|}
    ; {|{"schema":"keeper_event_queue.bulk.request.v2","action":"cancel","reason":"x","filter":{}}|}
    ; cancel_body []
    ; cancel_body [ selection_json "1"; selection_json "1" ]
    ; cancel_body [ selection_json "01" ]
    ; cancel_body [ `Assoc [ "keeper_name", `String "alpha"; "source_ref", `String (String.make 64 'a')
                          ; "source_incarnation", `Int 1 ] ]
    ; cancel_body [ `Assoc [ "keeper_name", `String "alpha"; "source_ref", `String (String.make 64 'a')
                          ; "source_incarnation", `String "1"; "all", `Bool true ] ] ]
;;

let test_selection_does_not_expand () =
  let original = List.hd (rows ()) in
  let selected = require_ok (Bulk.select_rows no_filter [ selection original ] (rows ())) in
  check int "only the previewed row" 1 (List.length selected);
  check string "same source" original.source_ref (List.hd selected).source_ref;
  Bulk.select_rows { keepers = Some [ "beta" ]; sources = None }
    [ selection original ] (rows ()) |> require_error;
  let advanced = { original with Bulk.source_incarnation = 2L } in
  Bulk.select_rows no_filter [ selection original ] [ advanced ] |> require_error
;;

let test_filters_and_age () =
  check int "keeper filter" 2
    (List.length (Bulk.plan_rows { keepers = Some [ "alpha" ]; sources = None } (rows ())));
  check int "source filter" 1
    (List.length (Bulk.plan_rows { keepers = None; sources = Some [ "schedule_due" ] } (rows ())));
  check (list (pair string int)) "keeper counts" [ "alpha", 2; "beta", 1 ]
    (Bulk.count_by (fun (row : Bulk.row) -> row.keeper_name) (rows ()));
  let unknown = { (List.hd (rows ())) with Bulk.first_admitted_at = None } in
  check (option (float 0.0)) "source timestamp does not invent admission age" None
    (Bulk.oldest_age_seconds [ unknown ]);
  check (option (float 0.0)) "empty has no age" None (Bulk.oldest_age_seconds [])
;;

let with_durable_queue f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool pool) (fun () ->
    let base_path = Filename.temp_file "bulk-exact-selection" "" in
    Sys.remove base_path;
    Unix.mkdir base_path 0o700;
    Fun.protect ~finally:(fun () -> rm_rf base_path) (fun () ->
      let config = Workspace_core.default_config base_path in
      ignore (Workspace_core.init config ~agent_name:(Some "test"));
      f ~config ~base_path ~keeper_name:"bulk-orphan"))
;;

let enqueue ~base_path ~keeper_name id =
  let source : Queue.stimulus =
    { post_id = id; urgency = Queue.Normal; arrived_at = Time_compat.now (); payload = Queue.Bootstrap }
  in
  Persistence.update_result ~base_path ~keeper_name (fun queue -> Queue.enqueue queue source)
  |> require_ok
;;

let read_pending ~base_path ~keeper_name =
  Persistence.load_state_result ~base_path ~keeper_name |> require_ok
;;

let test_two_cancellations_project_before_next () =
  with_durable_queue (fun ~config ~base_path ~keeper_name ->
    enqueue ~base_path ~keeper_name "first";
    enqueue ~base_path ~keeper_name "second";
    let planned = Bulk.rows_for_keeper ~base_path keeper_name |> require_ok in
    let results = Bulk.execute_rows ~cancel:(Bulk.cancel_row ~config)
                    ~operation_id:"same-owner" ~reason:"operator cleared both" planned in
    check int "both selected rows have outcomes" 2 (List.length results);
    List.iter (fun (result : Bulk.row_result) -> match result.status with
      | Bulk.Cancelled -> ()
      | Bulk.Committed_followup_failed -> fail "projection did not complete"
      | Bulk.Failed detail -> fail detail) results;
    let state = read_pending ~base_path ~keeper_name in
    check int "no pending work" 0 (List.length (State.pending_selections state));
    check int "no occupied transition outbox" 0 (List.length (State.transition_outbox state)))
;;

let test_new_enqueue_survives_execution () =
  with_durable_queue (fun ~config ~base_path ~keeper_name ->
    enqueue ~base_path ~keeper_name "previewed";
    let planned = Bulk.rows_for_keeper ~base_path keeper_name |> require_ok in
    enqueue ~base_path ~keeper_name "arrived-after-preview";
    let current = Bulk.rows_for_keeper ~base_path keeper_name |> require_ok in
    let selected = Bulk.select_rows no_filter (List.map selection planned) current |> require_ok in
    let results = Bulk.execute_rows ~cancel:(Bulk.cancel_row ~config)
                    ~operation_id:"frozen-target" ~reason:"only previewed" selected in
    check int "new row was not selected" 1 (List.length results);
    let ids = State.pending_selections (read_pending ~base_path ~keeper_name)
              |> List.map (fun (row : State.pending_selection) -> row.source.post_id) in
    check (list string) "new arrival survives" [ "arrived-after-preview" ] ids)
;;

let test_committed_projection_failure_stays_visible () =
  with_durable_queue (fun ~config ~base_path ~keeper_name ->
    enqueue ~base_path ~keeper_name "selected";
    let selected = Bulk.rows_for_keeper ~base_path keeper_name |> require_ok |> List.hd in
    let ledger = Masc.Keeper_reaction_ledger.store_dir ~base_path ~keeper_name in
    mkdir_p (Filename.dirname ledger);
    write_file ledger "a file blocks the ledger directory";
    let result = Bulk.cancel_row ~config ~operation_id:"projection-failure" ~reason:"operator" selected in
    (match result.status with
     | Bulk.Committed_followup_failed -> ()
     | Bulk.Cancelled -> fail "failed ledger projection reported complete"
     | Bulk.Failed detail -> fail ("committed cancellation became an unapplied error: " ^ detail));
    let state = read_pending ~base_path ~keeper_name in
    check int "primary cancellation remains committed" 0 (List.length (State.pending_selections state));
    check int "exact outbox retained for recovery" 1 (List.length (State.transition_outbox state)))
;;

(* The census must not turn a read failure into an empty fleet. The dry-run
   count and the executed set are the same plan, so a dropped keeper would
   make both wrong: the operator would read a failed read as an empty queue
   and cancel a subset while the inaccessible rows stay. *)
let test_census_read_failure_is_an_error () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_file "bulk_census_failure" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      Eio.Switch.run
      @@ fun sw ->
      let config = Workspace_core.default_config dir in
      ignore (Workspace_core.init config ~agent_name:(Some "test"));
      (match
         Keeper_owner_registry.install_from_store
           ~sw
           ~operation_runner:None
           ~on_turn_slot_released:None
           config
       with
       | Ok 0 -> ()
       | Ok count -> failf "expected empty owner inventory, got %d owners" count
       | Error error ->
         fail
           ("owner inventory install failed: "
            ^ Keeper_owner_registry.install_error_to_string error));
      let base_path = config.Workspace_utils_backend_setup.base_path in
      let keeper_name = "census-failure-keeper" in
      let meta =
        match
          Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String keeper_name ])
        with
        | Ok meta -> meta
        | Error detail -> fail ("keeper meta fixture failed: " ^ detail)
      in
      (match Keeper_owner_registry.create_meta ~base_path meta with
       | Ok (Some _) -> ()
       | Ok None -> fail "keeper create did not persist meta"
       | Error err ->
         fail
           ("keeper create failed: "
            ^ Keeper_owner_registry.command_error_to_string err));
      let keeper_dir =
        Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name
      in
      mkdir_p keeper_dir;
      let snapshot =
        Filename.concat keeper_dir Keeper_event_queue_persistence.snapshot_filename
      in
      write_file snapshot "{not-json";
      (match Bulk.rows_for_keeper ~base_path keeper_name with
       | Ok _ -> fail "a malformed queue read as an empty success"
       | Error _ -> ());
      match Bulk.all_rows config with
      | Ok _ -> fail "the fleet census read a malformed queue as an empty fleet"
      | Error _ -> ())
;;

(* The backup of a bulk operation is state this server writes, so it is kept
   with the rest under [.masc]. A workspace that never ran a bulk operation
   has no backup folder; the write makes it. *)
let test_backup_is_written_on_a_workspace_without_the_folder () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_file "bulk_backup_write" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      match
        Bulk.write_backup ~base_path:dir ~operation_id:"op-1" (`Assoc [ "rows", `List [] ])
      with
      | Error detail -> fail detail
      | Ok path ->
        check
          string
          "backup path"
          (Filename.concat dir ".masc/event-queue-bulk-backups/op-1.json")
          path;
        let ic = open_in path in
        let written =
          Fun.protect
            ~finally:(fun () -> close_in_noerr ic)
            (fun () -> really_input_string ic (in_channel_length ic))
        in
        check string "backup content" {|{"rows":[]}|} written)
;;

let () =
  run "keeper_event_queue_bulk"
    [ "codec", [ test_case "preview is read-only" `Quick test_preview
               ; test_case "int64 stays exact" `Quick test_int64_selection
               ; test_case "rejects ambiguous or unbound mutations" `Quick test_reject_ambiguous_requests ]
    ; "selection", [ test_case "selection cannot expand or cross filters" `Quick test_selection_does_not_expand
                   ; test_case "filters and admission age" `Quick test_filters_and_age ]
    ; "durable", [ test_case "two rows of one keeper finish their own outboxes" `Quick test_two_cancellations_project_before_next
                 ; test_case "new enqueue outside preview survives" `Quick test_new_enqueue_survives_execution
                 ; test_case "committed cancellation survives projection failure" `Quick test_committed_projection_failure_stays_visible ]
    ; "census", [ test_case "read failure stays an error" `Quick test_census_read_failure_is_an_error ]
    ; "backup", [ test_case "creates operation target record folder" `Quick test_backup_is_written_on_a_workspace_without_the_folder ] ]
