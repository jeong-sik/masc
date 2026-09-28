(* The fleet bulk cancel plans rows once and cancels exactly those rows, so a
   dry run and the execution it authorises can never disagree. These tests pin
   the pure planning and execution seams; the durable per-Keeper transition
   they call is covered by the event-queue suite. *)

open Alcotest

module Bulk = Server_dashboard_http_keeper_event_queue_bulk
module Keeper_owner_registry = Masc.Keeper_owner_registry

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
  rm dir
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let row ?(source_ref = String.make 64 'a') ?(source_incarnation = 1L) ~keeper ~source ~since () =
  { Bulk.keeper_name = keeper
  ; source_ref
  ; source_incarnation
  ; source_label = source
  ; since
  }
;;

let rows () =
  [ row ~keeper:"alpha" ~source:"board_signal" ~since:100.0 ()
  ; row ~keeper:"alpha" ~source:"schedule_due" ~since:90.0 ()
  ; row ~keeper:"beta" ~source:"board_signal" ~since:80.0 ()
  ]
;;

let test_parse_defaults_to_dry_run () =
  let body =
    {|{"schema":"keeper_event_queue.bulk.request.v1","action":"cancel","reason":"operator cleared the queue"}|}
  in
  match Bulk.parse body with
  | Error detail -> fail detail
  | Ok request ->
    check bool "dry run by default" true request.Bulk.dry_run;
    check (option string) "no confirm token" None request.confirm;
    check (option (list string)) "no keeper filter" None request.filter.keepers
;;

let test_parse_rejects_unknown_schema () =
  let body = {|{"schema":"nope","action":"cancel","reason":"x"}|} in
  match Bulk.parse body with
  | Ok _ -> fail "unknown schema was accepted"
  | Error _ -> ()
;;

let test_parse_accepts_execution_with_confirm () =
  let body =
    {|{"schema":"keeper_event_queue.bulk.request.v1","action":"cancel","dry_run":false,"confirm":"cancel-pending-events","reason":"operator cleared the queue"}|}
  in
  match Bulk.parse body with
  | Error detail -> fail detail
  | Ok request ->
    check bool "execution requested" false request.Bulk.dry_run;
    check (option string) "confirm token" (Some "cancel-pending-events") request.confirm
;;

let test_plan_filters_by_keeper () =
  let filter = { Bulk.keepers = Some [ "alpha" ]; sources = None } in
  let planned = Bulk.plan_rows filter (rows ()) in
  check int "only alpha rows" 2 (List.length planned);
  check bool "every planned row is alpha" true
    (List.for_all (fun r -> String.equal r.Bulk.keeper_name "alpha") planned)
;;

let test_plan_filters_by_source () =
  let filter = { Bulk.keepers = None; sources = Some [ "schedule_due" ] } in
  let planned = Bulk.plan_rows filter (rows ()) in
  check int "only schedule rows" 1 (List.length planned);
  check string "the schedule row's keeper" "alpha" (List.hd planned).Bulk.keeper_name
;;

let test_plan_without_filter_keeps_every_row () =
  let filter = { Bulk.keepers = None; sources = None } in
  check int "all rows" 3 (List.length (Bulk.plan_rows filter (rows ())))
;;

(* The invariant the operator relies on: the number a dry run reports is the
   number of rows the execution then cancels, and no filtered-out row is
   touched. *)
let test_execution_cancels_exactly_the_planned_rows () =
  let filter = { Bulk.keepers = Some [ "alpha" ]; sources = None } in
  let planned = Bulk.plan_rows filter (rows ()) in
  let seen = ref [] in
  let cancel ~operation_id:_ ~reason:_ r =
    seen := r :: !seen;
    `Assoc [ "keeper_name", `String r.Bulk.keeper_name; "ok", `Bool true ]
  in
  let results = Bulk.execute_rows ~cancel ~operation_id:"op" ~reason:"x" planned in
  check int "dry-run count equals executed count" (List.length planned)
    (List.length results);
  check int "recorder saw every planned row" (List.length planned)
    (List.length !seen);
  check bool "no beta row was cancelled" true
    (List.for_all (fun r -> not (String.equal r.Bulk.keeper_name "beta")) !seen)
;;

let test_count_by_keeper () =
  let counts = Bulk.count_by (fun r -> r.Bulk.keeper_name) (rows ()) in
  check (list (pair string int)) "keeper counts"
    [ "alpha", 2; "beta", 1 ]
    counts
;;

let test_oldest_age_is_positive () =
  match Bulk.oldest_age_seconds (rows ()) with
  | None -> fail "expected an oldest age"
  | Some age -> check bool "oldest age is positive" true (age > 0.0)
;;

let test_oldest_age_of_empty_is_none () =
  check (option (float 0.0)) "empty has no age" None (Bulk.oldest_age_seconds [])
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

let () =
  run
    "keeper_event_queue_bulk"
    [ ( "parse"
      , [ test_case "defaults to dry run" `Quick test_parse_defaults_to_dry_run
        ; test_case "rejects unknown schema" `Quick test_parse_rejects_unknown_schema
        ; test_case
            "accepts execution with confirm"
            `Quick
            test_parse_accepts_execution_with_confirm
        ] )
    ; ( "plan"
      , [ test_case "filters by keeper" `Quick test_plan_filters_by_keeper
        ; test_case "filters by source" `Quick test_plan_filters_by_source
        ; test_case
            "without filter keeps every row"
            `Quick
            test_plan_without_filter_keeps_every_row
        ] )
    ; ( "execute"
      , [ test_case
            "cancels exactly the planned rows"
            `Quick
            test_execution_cancels_exactly_the_planned_rows
        ] )
    ; ( "counts"
      , [ test_case "counts by keeper" `Quick test_count_by_keeper
        ; test_case "oldest age is positive" `Quick test_oldest_age_is_positive
        ; test_case "empty has no age" `Quick test_oldest_age_of_empty_is_none
        ] )
    ; ( "census"
      , [ test_case
            "a read failure is an error, not an empty fleet"
            `Quick
            test_census_read_failure_is_an_error
        ] )
    ]
;;
