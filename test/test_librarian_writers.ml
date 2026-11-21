(* The writers of a process (RFC librarian-call-only-proposes §8.6, §9.5,
   §11.1): a registered Keeper gets its one writer when it is first asked
   about, a Keeper that is not registered gets none, and a Keeper that was
   taken out and put back is written to again. *)

open Alcotest
module Writers = Masc.Librarian_writers
module Writer = Masc.Librarian_writer
module Machine = Masc.Librarian_machine
module Store = Masc.Librarian_store
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Envelope = Masc.Librarian_envelope
module Types = Masc.Keeper_memory_os_types
module Turn_log = Masc.Keeper_turn_log
module Turn_store = Masc.Keeper_turn_log_store
module Digest = Agent_core.Checkpoint_objects

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let mark : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages = 4
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let start_turn_log (place : Machine.place) =
  match
    Turn_store.append
      ~path:
        (Turn_store.path_for_keepers_dir ~keepers_dir:place.turns_dir ~keeper_id:place.keeper_id)
      ~at_end:0
      (Turn_log.Log_started { id = turn_log; at = 50.0; mark }, [])
  with
  | Ok (_ : Turn_store.appended) -> ()
  | Error (_ : Turn_store.append_error) -> fail "the turn log of the fixture was not written"
;;

(* Every line gets the next second. *)
let ticking () =
  let clock = ref 200.0 in
  fun () ->
    clock := !clock +. 1.0;
    !clock
;;

type fixture =
  { writers : Writers.t
  ; registered : string list ref
  ; memory_dir : string
  ; place : string -> Machine.place
  }

(* [keepers] are registered. Each has a turn log unless it is named in
   [without_turn_log]. [store_start] is the first step of every store start
   (§8.6), and [now] the clock every writer reads. *)
let fixture
      ?(without_turn_log = [])
      ?(store_start = fun (_ : string) -> Ok ())
      ?(now = ticking ())
      ~sw
      keepers
  =
  let memory_dir = Filename.temp_dir "memory" "" in
  let turns_dir = Filename.temp_dir "turns" "" in
  let place keeper_id : Machine.place = { memory_dir; turns_dir; keeper_id } in
  List.iter
    (fun keeper -> if not (List.mem keeper without_turn_log) then start_turn_log (place keeper))
    keepers;
  let registered = ref keepers in
  { writers =
      Writers.create ~sw ~now
        ~registered:(fun keeper -> List.mem keeper !registered)
        ~place
        ~stores:(fun keeper -> Masc_test_deps.stores_of_place (place keeper))
        ~ask:Masc_test_deps.never_asks ~ask_room:Masc_test_deps.never_makes_room
        ~start_turn_log:store_start
  ; registered
  ; memory_dir
  ; place
  }
;;

let with_switch body = Eio_main.run (fun (_ : Eio_unix.Stdenv.base) -> Eio.Switch.run body)

let stop_text : Store.stop -> string = function
  | Log_diverged _ -> "diverged"
  | Memory_unreadable -> "memory unreadable"
  | Log_unreadable -> "log unreadable"
  | Store_unwritable -> "store unwritable"
  | Raised { detail } -> "raised: " ^ detail
;;

let unavailable_text : Machine.unavailable -> string = function
  | Store_stopped stop -> "the store is stopped: " ^ stop_text stop
  | Keeper_retired -> "the keeper is retired"
;;

let write_text : Machine.write_answer -> string = function
  | Written line -> Printf.sprintf "written as commit %d" line.seq
  | Already_held -> "already held"
  | Already_done -> "already done"
  | Already_absent -> "already absent"
  | Refused refusal -> "refused: " ^ Direct.refusal_kind refusal
  | Not_a_snapshot (_ : Envelope.refusal) -> "not a snapshot"
  | Unavailable why -> unavailable_text why
;;

let act_text : Machine.act_answer -> string = function
  | Done -> "done"
  | Not_done Nothing_to_resume -> "nothing to resume"
  | Not_done Not_stopped -> "not stopped"
  | Not_done Snapshot_mismatch -> "snapshot mismatch"
  | Not_done Snapshot_unreadable -> "snapshot unreadable"
  | Not_done Not_replaced -> "not replaced"
  | Not_done Turn_log_unread -> "turn log unread"
  | Not_done (Not_the_head _) -> "not the head"
  | Not_done Not_the_faulted_line -> "not the faulted line"
  | Not_done Turn_log_stopped_on_line -> "the turn log is stopped on the line"
  | Not_done Content_unread -> "content unread"
  | Not_done (Act_unavailable why) -> unavailable_text why
;;

let retirement_text : Writer.retirement -> string = function
  | Retired_now -> "retired"
  | Still_registered -> "still registered"
;;

let status_text : Writer.status -> string = function
  | Booting -> "booting"
  | Open (Started _) -> "open at its start"
  | Open (Committed { seq; _ }) -> Printf.sprintf "open at commit %d" seq
  | Stopped stop -> "stopped: " ^ stop_text stop
  | Retired -> "retired"
;;

let statuses f =
  List.map (fun (keeper, status) -> keeper ^ ": " ^ status_text status) (Writers.statuses f.writers)
;;

(* What each writer holds, by the state of its machine (§12). *)
let held f =
  List.map
    (fun (keeper, (held : Writer.held)) ->
       keeper
       ^ ": "
       ^
       match held with
       | Held_booting -> "booting"
       | Held { state = Idle _; _ } -> "idle"
       | Held { state = Asking _; _ } -> "asking"
       | Held { state = Resting _; _ } -> "resting"
       | Held { state = Refused_at_bottom _; _ } -> "refused at the bottom"
       | Held { state = Stopped stop; _ } -> "stopped: " ^ stop_text stop
       | Held_retired -> "retired")
    (Writers.held f.writers)
;;

let view_text f keeper =
  match Writers.view f.writers keeper with
  | Error `Booting -> "booting"
  | Error (`Stopped stop) -> "stopped: " ^ stop_text stop
  | Error `No_writer -> "no writer"
  | Ok view ->
    Printf.sprintf "%s, from message %d"
      (match view.covers_through with
       | Before_first -> "nothing read"
       | Through _ -> "read")
      view.covered.closed_messages
;;

let remember claim =
  Direct.Remember
    { claim; category = Types.Constraint; basis = Types.Observed Types.Transcript }
;;

let write f keeper claim =
  write_text (Writers.write f.writers keeper ~by:Effects.Keeper ~trace:"turn" (remember claim))
;;

let port = "the port is 8935"
let owner = "the owner is the release team"
let probe = "the probe runs every minute"

let test_first_answer_is_booting () =
  with_switch (fun sw ->
    let f = fixture ~sw [ "keeper-a" ] in
    check (list string) "no writer before anyone asks" [] (statuses f);
    check string "the first reading makes the writer and does not wait for it" "booting"
      (view_text f "keeper-a");
    check (list string) "the table holds it" [ "keeper-a: booting" ] (statuses f);
    check string "a write waits for the boot" "written as commit 1" (write f "keeper-a" port);
    check string "the view is the line that write committed" "nothing read, from message 4"
      (view_text f "keeper-a"))
;;

let test_unregistered_keeper_has_no_writer () =
  with_switch (fun sw ->
    let f = fixture ~sw [] in
    (* It has a turn log: the writer is missing because of the registry. *)
    start_turn_log (f.place "keeper-a");
    check string "its view" "no writer" (view_text f "keeper-a");
    check string "a write" "the keeper is retired" (write f "keeper-a" port);
    check string "a resume" "the keeper is retired"
      (act_text (Writers.resume f.writers "keeper-a"));
    check string "an adoption" "the keeper is retired"
      (act_text
         (Writers.adopt f.writers "keeper-a" ~by:"operator-1"
            ~observed:(Digest.digest_of_bytes "anything")));
    check (list string) "no writer was made" [] (statuses f);
    check int "and no file of its Memory" 0 (Array.length (Sys.readdir f.memory_dir)))
;;

(* A second writer for the same Keeper would not get the lock, and its write
   would be refused as unwritable. *)
let test_one_writer_per_keeper () =
  with_switch (fun sw ->
    let f = fixture ~sw [ "keeper-a"; "keeper-b" ] in
    let first, second =
      Eio.Fiber.pair (fun () -> write f "keeper-a" port) (fun () -> write f "keeper-a" owner)
    in
    check string "the write that asked first" "written as commit 1" first;
    check string "the write that asked while the writer was booting" "written as commit 2" second;
    check string "another Keeper has its own writer and log" "written as commit 1"
      (write f "keeper-b" port);
    check (list string) "one writer each"
      [ "keeper-a: open at commit 2"; "keeper-b: open at commit 1" ]
      (statuses f))
;;

let test_stopped_and_resumed () =
  with_switch (fun sw ->
    let f = fixture ~without_turn_log:[ "keeper-a" ] ~sw [ "keeper-a" ] in
    check string "a Keeper without a turn log" "the store is stopped: store unwritable"
      (write f "keeper-a" port);
    check string "its view says why" "stopped: store unwritable" (view_text f "keeper-a");
    check (list string) "and what it holds is the stopped machine"
      [ "keeper-a: stopped: store unwritable" ] (held f);
    start_turn_log (f.place "keeper-a");
    check string "a resume" "done" (act_text (Writers.resume f.writers "keeper-a"));
    check string "opens it" "nothing read, from message 4" (view_text f "keeper-a");
    check (list string) "and it holds the open one" [ "keeper-a: idle" ] (held f);
    check string "an open store has nothing to resume" "nothing to resume"
      (act_text (Writers.resume f.writers "keeper-a")))
;;

let test_off_and_on_again () =
  with_switch (fun sw ->
    let f = fixture ~sw [ "keeper-a" ] in
    check string "while registered" "written as commit 1" (write f "keeper-a" port);
    f.registered := [];
    Writers.pulse f.writers [];
    (* Retirement runs asynchronously on the writers' switch so a retiring
       writer never stalls the global maintenance pulse. *)
    let rec wait_retired attempts =
      if statuses f = [] || attempts <= 0
      then ()
      else (
        Eio.Fiber.yield ();
        wait_retired (attempts - 1))
    in
    wait_retired 50;
    check (list string) "the pulse retires the writer of a Keeper that is gone" [] (statuses f);
    check string "its Memory takes no write" "the keeper is retired" (write f "keeper-a" owner);
    check string "and has no view" "no writer" (view_text f "keeper-a");
    f.registered := [ "keeper-a" ];
    check string "registered again, its write is not refused" "written as commit 2"
      (write f "keeper-a" owner);
    check (list string) "by a new writer that read the log the first one left"
      [ "keeper-a: open at commit 2" ]
      (statuses f))
;;

let test_retire_before_the_files_go () =
  with_switch (fun sw ->
    let f = fixture ~sw [ "keeper-a" ] in
    let retire () = retirement_text (Writers.retire f.writers "keeper-a") in
    check string "a Keeper that has no writer" "retired" (retire ());
    check string "its first write" "written as commit 1" (write f "keeper-a" port);
    check string "a registered Keeper's writer is not retired" "still registered" (retire ());
    check string "and goes on" "written as commit 2" (write f "keeper-a" owner);
    f.registered := [];
    check string "out of the registry, it is" "retired" (retire ());
    check (list string) "and leaves the table" [] (statuses f);
    (* Nothing holds the files: a writer outside the table takes the lock. *)
    let bare =
      Writer.create ~now:(ticking ()) ~registered:(fun () -> true) ~declared:(fun () -> None)
        ~stores:(Masc_test_deps.stores_of_place (f.place "keeper-a")) ~ask:Masc_test_deps.never_asks ~ask_room:Masc_test_deps.never_makes_room
        ~start_turn_log:(fun () -> Ok ())
        (f.place "keeper-a")
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Writer.run bare;
      `Stop_daemon);
    check string "the lock is free" "written as commit 3"
      (match Writer.write bare ~by:Effects.Keeper ~trace:"turn" (remember probe) with
       | Answered answer -> write_text answer
       | Ended -> "the writer ended"))
;;

let test_pulse_gives_every_registered_keeper_its_writer () =
  with_switch (fun sw ->
    let f = fixture ~sw [ "keeper-a"; "keeper-b" ] in
    Writers.pulse f.writers [ "keeper-a"; "keeper-b"; "keeper-c" ];
    check (list string) "before anyone asks, and none for the one that is not registered"
      [ "keeper-a: booting"; "keeper-b: booting" ]
      (statuses f);
    check string "the writer the pulse made takes the write" "written as commit 1"
      (write f "keeper-a" port))
;;

(* §9.2: a writer whose own code raises stops, and no other writer does. It
   stays in the table and takes its events, so nothing boots it again but a
   resume. *)
let test_a_boot_that_raises_stops_its_writer_only () =
  with_switch (fun sw ->
    let raising = ref true in
    let store_start keeper =
      if !raising && String.equal keeper "keeper-a"
      then failwith "the store start raised"
      else Ok ()
    in
    let f = fixture ~store_start ~sw [ "keeper-a"; "keeper-b" ] in
    let stopped = "the store is stopped: raised: Failure(\"the store start raised\")" in
    check string "a write to the writer whose boot raised" stopped (write f "keeper-a" port);
    check string "another Keeper's writer goes on" "written as commit 1" (write f "keeper-b" port);
    Writers.turn_closed f.writers "keeper-a";
    Writers.pulse f.writers [ "keeper-a"; "keeper-b" ];
    check string "a closed turn and a pulse do not boot it again" stopped
      (write f "keeper-a" owner);
    check (list string) "both stay in the table"
      [ "keeper-a: stopped: raised: Failure(\"the store start raised\")"
      ; "keeper-b: open at commit 1"
      ]
      (statuses f);
    raising := false;
    check string "a resume" "done" (act_text (Writers.resume f.writers "keeper-a"));
    check string "boots it again" "written as commit 1" (write f "keeper-a" port))
;;

(* The event that raised is answered, and the next boot reads the log the
   writer left. *)
let test_an_event_that_raises_answers_its_caller () =
  with_switch (fun sw ->
    let raising = ref false in
    let clock = ticking () in
    let now () = if !raising then failwith "the clock raised" else clock () in
    let f = fixture ~now ~sw [ "keeper-a"; "keeper-b" ] in
    check string "a write before" "written as commit 1" (write f "keeper-a" port);
    raising := true;
    check string "the write whose event raised"
      "the store is stopped: raised: Failure(\"the clock raised\")" (write f "keeper-a" owner);
    raising := false;
    check string "another Keeper's writer goes on" "written as commit 1" (write f "keeper-b" port);
    check string "a resume" "done" (act_text (Writers.resume f.writers "keeper-a"));
    check string "boots from the log the writer left" "written as commit 2"
      (write f "keeper-a" owner))
;;

(* Cancellation and the reserved exceptions are not a writer's to stop on:
   they end the switch the writers run in. *)
let test_a_reserved_exception_goes_up () =
  check_raises "Sys.Break ends the switch" Sys.Break (fun () ->
    with_switch (fun sw ->
      let f = fixture ~store_start:(fun (_ : string) -> raise Sys.Break) ~sw [ "keeper-a" ] in
      ignore (write f "keeper-a" port : string)))
;;

let test_world_promotions_dispatch_once_across_compact_and_subsequent_events () =
  with_switch (fun sw ->
    let memory_dir = Filename.temp_dir "memory_promo" "" in
    let turns_dir = Filename.temp_dir "turns_promo" "" in
    let place keeper_id : Machine.place = { memory_dir; turns_dir; keeper_id } in
    start_turn_log (place "keeper-a");
    let asks_done = ref 0 in
    let dispatched : (string * Masc.Librarian_lifecycle.world_promotion list) list ref = ref [] in
    let question_id =
      match
        Masc.Librarian_question_id.of_halves
          ~front:(String.make 32 '1') ~back:(String.make 32 '2')
      with
      | Some id -> id
      | None -> fail "invalid test question id"
    in
    let ask_room (input : Masc.Librarian_ask.room_input) : Masc.Librarian_room_result.t =
      let line =
        match input.tail () with
        | Some line -> line
        | None -> fail "writer tail unavailable during molt ask"
      in
      let snap_path =
        Masc.Keeper_memory_os_current_layout.path_for_keepers_dir
          ~keepers_dir:input.place.memory_dir ~keeper_id:input.place.keeper_id
      in
      let snap =
        let raw = In_channel.with_open_bin snap_path In_channel.input_all in
        match Masc.Keeper_memory_os_snapshot_codec.of_json (Yojson.Safe.from_string raw) with
        | Ok s -> s
        | Error _ -> fail "snapshot decode failed in molt ask"
      in
      let memory =
        List.mapi (fun i f -> Printf.sprintf "m%d" (i + 1), Types.memory_id f) snap.facts
      in
      let answer : Masc.Librarian_answer.t =
        { question = question_id
        ; working_state = Keep
        ; ops =
            [ Promote_to_world
                { refs = [ "m1" ]
                ; scope = "workspace"
                ; claim = "Promoted invariant from " ^ input.asked.trace
                ; category = Constraint
                ; facets = [ "sqlite_wal" ]
                }
            ]
        }
      in
      let question : Masc.Librarian_room_result.question =
        { id = question_id
        ; memory
        ; basis = Masc.Librarian_log.snapshot_after line
        ; trace = input.asked.trace
        }
      in
      incr asks_done;
      Room_answered { question; answer; slot = "claude_code.fast" }
    in
    let writers =
      Writers.create ~sw ~now:(ticking ())
        ~registered:(fun k -> String.equal k "keeper-a")
        ~place
        ~stores:(fun k -> Masc_test_deps.stores_of_place (place k))
        ~ask:Masc_test_deps.never_asks
        ~ask_room
        ~start_turn_log:(fun (_ : string) -> Ok ())
    in
    Writers.set_world_promotions_callback writers
      (Some (fun ~keeper_id promos -> dispatched := (keeper_id, promos) :: !dispatched));
    let lane_slot : Masc.Librarian_memory_lane.slot_key =
      { id = "claude_code.fast"
      ; target = Cli { runtime_id = "claude_code.fast"; api_name = "claude-sonnet-5" }
      ; window = 200_000
      }
    in
    let declared : Machine.declared =
      { value =
          { question =
              { prompt = "memory prompt"
              ; answer_schemas =
                  { Masc.Librarian_memory_lane.range = `Assoc [ "type", `String "object" ]
                  ; item_alone = `Assoc [ "type", `String "object" ]
                  ; room = `Assoc [ "type", `String "object" ]
                  }
              ; max_output_tokens = 4096
              ; thinking = None
              }
          ; http = []
          ; cli = [ lane_slot ]
          ; unadmitted = []
          }
      ; resolved = { Runtime_exact_output_registry.selected_slots = []; cli_slots = [] }
      }
    in
    Writers.declaration_changed writers (Some declared);
    let sync_write trace claim =
      Writers.write writers "keeper-a" ~by:Effects.Keeper ~trace (remember claim)
    in
    check string "seed fact committed" "written as commit 1"
      (write_text (sync_write "turn-1" port));
    let wait_until pred =
      let rec loop attempts =
        if pred () then ()
        else if attempts <= 0 then fail "timed out waiting for writer state"
        else (
          Eio.Fiber.yield ();
          loop (attempts - 1))
      in
      loop 200
    in
    let writer_idle () =
      match Writers.held writers with
      | [ "keeper-a", Writer.Held { state = Idle _; _ } ] -> true
      | _ -> false
    in
    (* Epoch 1: promotion-only molt commits via Store.changes, compacts log
       (advancing tail seq beyond the promotion seq), and dispatches once. *)
    Writers.compaction_epoch_advanced writers "keeper-a" ~epoch_id:1;
    wait_until (fun () -> !asks_done >= 1 && writer_idle ());
    check int "epoch 1 promotion dispatched exactly once" 1 (List.length !dispatched);
    (* Subsequent events after compact_log must NOT re-emit the previous promotion. *)
    Writers.pulse writers [ "keeper-a" ];
    Writers.turn_closed writers "keeper-a";
    ignore (sync_write "turn-2" owner : Machine.write_answer);
    Writers.pulse writers [ "keeper-a" ];
    ignore (sync_write "turn-3" probe : Machine.write_answer);
    check int "no duplicate promotion dispatch after pulse/turn_closed/writes"
      1 (List.length !dispatched);
    (* Epoch 2: a genuinely new promotion batch dispatches once more, and again
       does not re-emit on subsequent events. *)
    Writers.compaction_epoch_advanced writers "keeper-a" ~epoch_id:2;
    wait_until (fun () -> !asks_done >= 2 && writer_idle ());
    Writers.pulse writers [ "keeper-a" ];
    ignore (sync_write "turn-4" probe : Machine.write_answer);
    check int "epoch 2 new promotion dispatched exactly once (total 2)"
      2 (List.length !dispatched))
;;

let () =
  run "librarian_writers"
    [ ( "a registered Keeper"
      , [ test_case "the first answer is booting" `Quick test_first_answer_is_booting
        ; test_case "has one writer" `Quick test_one_writer_per_keeper
        ; test_case "stopped and resumed" `Quick test_stopped_and_resumed
        ] )
    ; ( "the registry"
      , [ test_case "a Keeper that is not registered has no writer" `Quick
            test_unregistered_keeper_has_no_writer
        ; test_case "off and on again" `Quick test_off_and_on_again
        ; test_case "retire before the files go" `Quick test_retire_before_the_files_go
        ; test_case "the pulse" `Quick test_pulse_gives_every_registered_keeper_its_writer
        ] )
    ; ( "a writer whose code raises"
      , [ test_case "a boot that raises stops its writer only" `Quick
            test_a_boot_that_raises_stops_its_writer_only
        ; test_case "an event that raises answers its caller" `Quick
            test_an_event_that_raises_answers_its_caller
        ; test_case "a reserved exception goes up" `Quick test_a_reserved_exception_goes_up
        ] )
    ; ( "world promotions"
      , [ test_case "promotion-only molt dispatches once across compact_log and later events"
            `Quick test_world_promotions_dispatch_once_across_compact_and_subsequent_events
        ] )
    ]
;;
