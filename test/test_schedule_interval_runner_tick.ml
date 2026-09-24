(** Where create/modify and load part ways on an interval (#38176).

    The schedule runner looks for due schedules once per tick, so an interval
    shorter than the tick fires once per tick. Create and modify refuse such an
    interval, so a stored interval says how often it fires. Load accepts any
    positive interval, so a row stored before the tick check keeps loading, and
    a modify that carries its interval back unchanged is accepted, so its
    payload can still be edited.

    The two paths therefore differ exactly on [1, tick): below the tick create
    refuses and load accepts; from the tick up both accept; at or below zero
    both refuse. *)

open Alcotest

let runner_tick_sec = 15.0

let actor =
  { Schedule_domain.id = "k1"
  ; kind = Schedule_domain.Automated_actor
  ; display_name = None
  }
;;

let requested_at = 1789570000.0

(* A payload [payload_of_yojson] accepts, so an interval is the only thing a
   case can be refused for. *)
let payload text =
  `Assoc [ "kind", `String "consumer.note"; "body", `Assoc [ "text", `String text ] ]
;;

let request ?(schedule_id = "sched-interval-tick") ?(text = "wake") interval_sec =
  Schedule_domain.create_request
    ~schedule_id
    ~requested_by:actor
    ~scheduled_by:actor
    ~requested_at
    ~due_at:requested_at
    ~payload:(payload text)
    ~source:Schedule_domain.Automated_request
    ~recurrence:(Schedule_domain.Interval { interval_sec })
    ()
;;

let request_exn ?schedule_id ?text interval_sec =
  match request ?schedule_id ?text interval_sec with
  | Ok request -> request
  | Error err -> failf "interval %ds request was refused: %s" interval_sec err
;;

(* The create path: the request must be well formed, and the runner must fire
   it as often as it declares. *)
let created interval_sec =
  match request interval_sec with
  | Error _ -> false
  | Ok request ->
    Result.is_ok
      (Schedule_domain.interval_fires_as_declared ~runner_tick_sec ~stored:None
         request.recurrence)
;;

(* The load path: a row the codec itself wrote, with only its recurrence
   replaced, read back through the ledger decoder. *)
let loaded_row interval_sec =
  match Schedule_domain.schedule_request_to_yojson (request_exn 3600) with
  | `Assoc fields ->
    Schedule_domain.schedule_request_of_yojson
      (`Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "recurrence"
              then
                ( name
                , `Assoc [ "kind", `String "interval"; "interval_sec", `Int interval_sec ] )
              else name, value)
           fields))
  | _ -> failf "schedule_request_to_yojson did not write an object"
;;

let loaded interval_sec = Result.is_ok (loaded_row interval_sec)

let tick_boundary = int_of_float runner_tick_sec
let below_tick = [ 1; tick_boundary - 1 ]
let at_or_above_tick = [ tick_boundary; tick_boundary + 1; 3600 ]
let nonpositive = [ 0; -5 ]

let expect_paths ~created:want_created ~loaded:want_loaded interval_sec =
  check bool (Printf.sprintf "interval %ds: create" interval_sec) want_created
    (created interval_sec);
  check bool (Printf.sprintf "interval %ds: load" interval_sec) want_loaded
    (loaded interval_sec)
;;

let test_below_tick_loads_but_is_not_created () =
  List.iter (expect_paths ~created:false ~loaded:true) below_tick
;;

let test_from_tick_both_accept () =
  List.iter (expect_paths ~created:true ~loaded:true) at_or_above_tick
;;

let test_nonpositive_both_refuse () =
  List.iter (expect_paths ~created:false ~loaded:false) nonpositive
;;

let test_loaded_row_keeps_its_interval () =
  List.iter
    (fun interval_sec ->
       match loaded_row interval_sec with
       | Ok { Schedule_domain.recurrence = Schedule_domain.Interval { interval_sec = read }; _ } ->
         check int "stored interval read back unchanged" interval_sec read
       | Ok _ -> failf "interval %ds loaded as another recurrence kind" interval_sec
       | Error err -> failf "interval %ds refused on load: %s" interval_sec err)
    (below_tick @ at_or_above_tick)
;;

(* --- Modify, against a real ledger ------------------------------------ *)

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_dir "schedule_interval_tick_test" "" in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> Masc_test_deps.cleanup_test_workspace dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  f config
;;

(* A row below the tick, stored while the runner ran on a shorter tick. *)
let below_tick_interval = 1
let stored_under_tick = 1.0

let store_below_tick_row config =
  let row = request_exn below_tick_interval in
  match Schedule_store.insert_request config ~runner_tick_sec:stored_under_tick row with
  | Ok row -> row
  | Error err -> failf "fixture row refused: %s" (Schedule_store.store_error_to_string err)
;;

let modify config ~text interval_sec =
  Schedule_store.update_request config ~now:requested_at ~runner_tick_sec
    (request_exn ~schedule_id:"sched-interval-tick" ~text interval_sec)
;;

let test_modify_keeping_the_interval_is_accepted () =
  with_workspace
  @@ fun config ->
  ignore (store_below_tick_row config);
  match modify config ~text:"edited payload" below_tick_interval with
  | Ok { Schedule_domain.recurrence = Schedule_domain.Interval { interval_sec }; _ } ->
    check int "interval kept" below_tick_interval interval_sec
  | Ok _ -> fail "modify changed the recurrence kind"
  | Error err ->
    failf "payload edit of a below-tick row was refused: %s"
      (Schedule_store.store_error_to_string err)
;;

let test_modify_to_another_below_tick_interval_is_refused () =
  with_workspace
  @@ fun config ->
  ignore (store_below_tick_row config);
  let changed = below_tick_interval + 1 in
  match modify config ~text:"wake" changed with
  | Error
      (Schedule_store.Interval_below_runner_tick
        { schedule_id; below = { interval_sec; runner_tick_sec = tick } }) ->
    check string "names the schedule" "sched-interval-tick" schedule_id;
    check int "names the interval" changed interval_sec;
    check (float 0.0) "names the tick" runner_tick_sec tick
  | Error err ->
    failf "expected Interval_below_runner_tick, got %s"
      (Schedule_store.store_error_to_string err)
  | Ok _ -> fail "modify accepted a changed interval below the tick"
;;

let test_modify_up_to_the_tick_is_accepted () =
  with_workspace
  @@ fun config ->
  ignore (store_below_tick_row config);
  match modify config ~text:"wake" tick_boundary with
  | Ok _ -> ()
  | Error err ->
    failf "modify to the tick was refused: %s" (Schedule_store.store_error_to_string err)
;;

let test_create_below_tick_is_refused_by_the_store () =
  with_workspace
  @@ fun config ->
  match
    Schedule_store.insert_request config ~runner_tick_sec (request_exn below_tick_interval)
  with
  | Error (Schedule_store.Interval_below_runner_tick _) -> ()
  | Error err ->
    failf "expected Interval_below_runner_tick, got %s"
      (Schedule_store.store_error_to_string err)
  | Ok _ -> fail "insert accepted an interval below the tick"
;;

let () =
  run
    "schedule_interval_runner_tick"
    [ ( "create and load"
      , [ test_case "below the tick: load only" `Quick
            test_below_tick_loads_but_is_not_created
        ; test_case "from the tick: both" `Quick test_from_tick_both_accept
        ; test_case "non-positive: neither" `Quick test_nonpositive_both_refuse
        ; test_case "a loaded row keeps its interval" `Quick
            test_loaded_row_keeps_its_interval
        ] )
    ; ( "store"
      , [ test_case "create below the tick refused" `Quick
            test_create_below_tick_is_refused_by_the_store
        ; test_case "modify keeping the interval accepted" `Quick
            test_modify_keeping_the_interval_is_accepted
        ; test_case "modify to another below-tick interval refused" `Quick
            test_modify_to_another_below_tick_interval_is_refused
        ; test_case "modify up to the tick accepted" `Quick
            test_modify_up_to_the_tick_is_accepted
        ] )
    ]
;;
